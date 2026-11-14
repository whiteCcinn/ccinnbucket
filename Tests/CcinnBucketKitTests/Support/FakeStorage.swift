import Foundation
import os
import StorageKit

/// Minimal in-memory `ObjectStorage` for MCP and app-logic tests (objects, versions-free, call counting).
final class FakeStorage: ObjectStorage {
    struct Object: Sendable {
        var data: Data
        var contentType: String?
        var lastModified: Date
    }

    struct State: Sendable {
        var buckets: [String: [String: Object]] = [:]
        var calls: [String] = []
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    /// Called at the start of every listing; may sleep to simulate a slow server.
    let listHook: @Sendable () async throws -> Void

    init(listHook: @escaping @Sendable () async throws -> Void = {}) {
        self.listHook = listHook
    }

    func put(_ bucket: String, _ key: String, _ text: String, contentType: String? = "text/plain") {
        put(bucket, key, Data(text.utf8), contentType: contentType)
    }

    func put(_ bucket: String, _ key: String, _ data: Data, contentType: String?) {
        state.withLock { $0.buckets[bucket, default: [:]][key] = Object(data: data, contentType: contentType, lastModified: Date(timeIntervalSince1970: 1_700_000_000)) }
    }

    var calls: [String] { state.withLock { $0.calls } }

    private func record(_ name: String) { state.withLock { $0.calls.append(name) } }

    private func object(_ bucket: String, _ key: String) throws -> Object {
        guard let object = state.withLock({ $0.buckets[bucket]?[key] }) else {
            throw StorageError(kind: .service, code: "NoSuchKey", message: "The specified key does not exist.", statusCode: 404)
        }
        return object
    }

    var capabilities: StorageCapabilities {
        StorageCapabilities(provider: .s3, storageClasses: ["STANDARD"], defaultStorageClass: "STANDARD", maxSingleCopySize: 5 << 30, maxPresignExpiry: 604_800)
    }

    var isReadOnly: Bool { false }

    func listBuckets() async throws -> [BucketInfo] {
        record("listBuckets")
        return state.withLock { $0.buckets.keys.sorted().map { BucketInfo(name: $0, creationDate: Date(timeIntervalSince1970: 1_700_000_000), region: "us-east-1") } }
    }

    func createBucket(_ name: String, region: String?) async throws { record("createBucket") }
    func deleteBucket(_ name: String) async throws { record("deleteBucket") }
    func bucketLocation(_ bucket: String) async throws -> String? { "us-east-1" }
    func headBucket(_ bucket: String) async throws {}

    func listObjects(_ request: ListObjectsRequest) async throws -> ListPage {
        record("listObjects")
        try await listHook()
        try Task.checkCancellation()
        let all = state.withLock { ($0.buckets[request.bucket] ?? [:]).keys.filter { $0.hasPrefix(request.prefix) }.sorted() }
        var prefixes: [String] = []
        var keys: [String] = []
        for key in all {
            let rest = key.dropFirst(request.prefix.count)
            if let delimiter = request.delimiter, let range = rest.range(of: delimiter) {
                let common = request.prefix + rest[..<range.upperBound]
                if prefixes.last != common { prefixes.append(String(common)) }
            } else {
                keys.append(key)
            }
        }
        var start = 0
        if case let .continuation(token)? = request.token { start = Int(token) ?? 0 }
        let page = Array(keys.dropFirst(start).prefix(request.maxKeys))
        let next = start + page.count
        let objects = try page.map { key -> ObjectEntry in
            let stored = try object(request.bucket, key)
            return ObjectEntry(key: key, size: Int64(stored.data.count), lastModified: stored.lastModified, eTag: "\"e\"", storageClass: "STANDARD")
        }
        return ListPage(objects: objects, commonPrefixes: start == 0 ? prefixes : [], isTruncated: next < keys.count,
                        nextToken: next < keys.count ? .continuation(String(next)) : nil, apiVersion: .v2)
    }

    func listObjectVersions(_ request: VersionListRequest) async throws -> VersionPage {
        record("listObjectVersions")
        let keys = state.withLock { ($0.buckets[request.bucket] ?? [:]).keys.filter { $0.hasPrefix(request.prefix) }.sorted() }
        let versions = keys.map { ObjectVersion(key: $0, versionID: "v1", isLatest: true, isDeleteMarker: false, size: 1) }
        return VersionPage(versions: versions, commonPrefixes: [], isTruncated: false, nextKeyMarker: nil, nextVersionIDMarker: nil)
    }

    func listMultipartUploads(bucket: String, prefix: String, keyMarker: String?, uploadIDMarker: String?) async throws -> MultipartUploadsPage {
        MultipartUploadsPage(uploads: [], commonPrefixes: [], isTruncated: false, nextKeyMarker: nil, nextUploadIDMarker: nil)
    }

    func headObject(bucket: String, key: String, versionID: String?) async throws -> ObjectMetadata {
        record("headObject")
        let stored = try object(bucket, key)
        return ObjectMetadata(key: key, size: Int64(stored.data.count), eTag: "\"e\"", lastModified: stored.lastModified, contentType: stored.contentType,
                              userMetadata: ["owner": "test"])
    }

    func getObject(bucket: String, key: String, versionID: String?, range: ByteRange?, maxBytes: Int) async throws -> ObjectData {
        record("getObject")
        let stored = try object(bucket, key)
        var data = stored.data
        if let range {
            let first = Int(min(range.first, Int64(data.count)))
            let last = Int(min(range.last + 1, Int64(data.count)))
            data = data.subdata(in: first..<max(first, last))
        }
        let metadata = try await headObject(bucket: bucket, key: key, versionID: versionID)
        return ObjectData(data: data.prefix(maxBytes), metadata: metadata, totalSize: Int64(stored.data.count))
    }

    func downloadObject(bucket: String, key: String, versionID: String?, range: ByteRange?, ifMatch: String?, descriptor: Int32,
                        fileOffset: Int64, progress: TransferProgressHandler?) async throws -> ObjectMetadata {
        throw StorageError.invalidRequest("not supported")
    }

    func putObject(bucket: String, key: String, body: Data, options: ObjectWriteOptions, progress: TransferProgressHandler?) async throws -> PutResult {
        record("putObject")
        put(bucket, key, body, contentType: options.contentType)
        return PutResult(eTag: "\"new\"", versionID: nil)
    }

    func deleteObject(bucket: String, key: String, versionID: String?) async throws {
        record("deleteObject")
        _ = state.withLock { $0.buckets[bucket]?.removeValue(forKey: key) }
    }

    func deleteObjects(bucket: String, objects: [ObjectReference]) async throws -> DeleteResult {
        record("deleteObjects")
        state.withLock { state in for object in objects { state.buckets[bucket]?.removeValue(forKey: object.key) } }
        return DeleteResult(deleted: objects)
    }

    func copyObject(_ request: CopyObjectRequest) async throws -> PutResult {
        record("copyObject")
        let source = try object(request.sourceBucket, request.sourceKey)
        put(request.destinationBucket, request.destinationKey, source.data, contentType: source.contentType)
        return PutResult(eTag: "\"copy\"")
    }

    func getObjectTags(bucket: String, key: String, versionID: String?) async throws -> [ObjectTag] { [] }
    func putObjectTags(bucket: String, key: String, versionID: String?, tags: [ObjectTag]) async throws { record("putObjectTags") }
    func createMultipartUpload(bucket: String, key: String, options: ObjectWriteOptions) async throws -> String { "u" }
    func uploadPart(bucket: String, key: String, uploadID: String, partNumber: Int, body: Data, progress: TransferProgressHandler?) async throws -> UploadedPart {
        UploadedPart(partNumber: partNumber, eTag: "e", size: Int64(body.count))
    }
    func uploadPartCopy(bucket: String, key: String, uploadID: String, partNumber: Int, sourceBucket: String, sourceKey: String,
                        sourceVersionID: String?, range: ByteRange) async throws -> UploadedPart {
        UploadedPart(partNumber: partNumber, eTag: "e", size: range.length)
    }
    func completeMultipartUpload(bucket: String, key: String, uploadID: String, parts: [UploadedPart]) async throws -> PutResult { PutResult() }
    func abortMultipartUpload(bucket: String, key: String, uploadID: String) async throws {}
    func listParts(bucket: String, key: String, uploadID: String) async throws -> [UploadedPart] { [] }
    func bucketSetting(_ kind: BucketSettingKind, bucket: String) async throws -> BucketSettingDocument { BucketSettingDocument(kind: kind, state: .notConfigured) }
    func versioningStatus(bucket: String) async throws -> VersioningStatus { .unversioned }
    func setVersioning(bucket: String, enabled: Bool) async throws {}

    func presignedURL(bucket: String, key: String, versionID: String?, method: String, expires: Int,
                      responseContentDisposition: String?) async throws -> URL {
        record("presignedURL")
        guard let url = URL(string: "https://example.invalid/\(bucket)/\(key)?X-Amz-Expires=\(expires)") else { throw StorageError.invalidRequest("bad") }
        return url
    }
}
