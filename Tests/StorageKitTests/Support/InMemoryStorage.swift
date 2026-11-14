import Foundation
import os
@testable import StorageKit

/// In-memory `ObjectStorage` for engine tests: objects, multipart uploads, call counters and hooks.
final class InMemoryStorage: ObjectStorage {
    struct Stored: Sendable {
        var data: Data
        var eTag: String
        var options: ObjectWriteOptions
    }

    struct Upload: Sendable {
        var bucket: String
        var key: String
        var options: ObjectWriteOptions
        var parts: [Int: (data: Data, eTag: String)]
    }

    struct State: Sendable {
        var objects: [String: Stored] = [:]
        var uploads: [String: Upload] = [:]
        var calls: [String: Int] = [:]
        var activeParts = 0
        var maxActiveParts = 0
        var uploadedPartNumbers: [Int] = []
        var downloadedRanges: [ByteRange] = []
        var nextUploadID = 1
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    let maxCopy: Int64
    /// Called before a part upload / ranged download; may sleep or throw to simulate slow or failing parts.
    let partHook: @Sendable (Int) async throws -> Void
    let rangeHook: @Sendable (ByteRange) async throws -> Void

    init(maxSingleCopySize: Int64 = 5 << 30, partHook: @escaping @Sendable (Int) async throws -> Void = { _ in },
         rangeHook: @escaping @Sendable (ByteRange) async throws -> Void = { _ in }) {
        maxCopy = maxSingleCopySize
        self.partHook = partHook
        self.rangeHook = rangeHook
    }

    private static func id(_ bucket: String, _ key: String) -> String { bucket + "/" + key }

    func count(_ name: String) -> Int { state.withLock { $0.calls[name, default: 0] } }

    private func record(_ name: String) { state.withLock { $0.calls[name, default: 0] += 1 } }

    func object(_ bucket: String, _ key: String) -> Stored? { state.withLock { $0.objects[Self.id(bucket, key)] } }

    func store(_ bucket: String, _ key: String, _ data: Data, options: ObjectWriteOptions = ObjectWriteOptions()) {
        state.withLock { $0.objects[Self.id(bucket, key)] = Stored(data: data, eTag: "\"\(data.hashValue)\"", options: options) }
    }

    var capabilities: StorageCapabilities {
        StorageCapabilities(provider: .s3, storageClasses: ["STANDARD"], defaultStorageClass: "STANDARD", maxSingleCopySize: maxCopy,
                            maxPresignExpiry: 604_800)
    }

    var isReadOnly: Bool { false }

    func listBuckets() async throws -> [BucketInfo] { [] }
    func createBucket(_ name: String, region: String?) async throws {}
    func deleteBucket(_ name: String) async throws {}
    func bucketLocation(_ bucket: String) async throws -> String? { nil }
    func headBucket(_ bucket: String) async throws {}

    func listObjects(_ request: ListObjectsRequest) async throws -> ListPage {
        record("listObjects")
        let keys = state.withLock { state in
            state.objects.keys.filter { $0.hasPrefix(request.bucket + "/" + request.prefix) }.map { String($0.dropFirst(request.bucket.count + 1)) }.sorted()
        }
        var start = 0
        if case let .continuation(token)? = request.token, let index = Int(token) { start = index }
        let slice = Array(keys.dropFirst(start).prefix(request.maxKeys))
        let next = start + slice.count
        let objects = slice.map { key in ObjectEntry(key: key, size: Int64(object(request.bucket, key)?.data.count ?? 0)) }
        return ListPage(objects: objects, commonPrefixes: [], isTruncated: next < keys.count,
                        nextToken: next < keys.count ? .continuation(String(next)) : nil, apiVersion: .v2)
    }

    func listObjectVersions(_ request: VersionListRequest) async throws -> VersionPage {
        VersionPage(versions: [], commonPrefixes: [], isTruncated: false, nextKeyMarker: nil, nextVersionIDMarker: nil)
    }

    func listMultipartUploads(bucket: String, prefix: String, keyMarker: String?, uploadIDMarker: String?) async throws -> MultipartUploadsPage {
        let uploads = state.withLock { $0.uploads.map { MultipartUploadInfo(key: $0.value.key, uploadID: $0.key) } }
        return MultipartUploadsPage(uploads: uploads, commonPrefixes: [], isTruncated: false, nextKeyMarker: nil, nextUploadIDMarker: nil)
    }

    func headObject(bucket: String, key: String, versionID: String?) async throws -> ObjectMetadata {
        record("headObject")
        guard let stored = object(bucket, key) else { throw StorageError(kind: .service, code: "NoSuchKey", message: "missing", statusCode: 404) }
        var metadata = ObjectMetadata(key: key, size: Int64(stored.data.count), eTag: stored.eTag, contentType: stored.options.contentType,
                                      userMetadata: stored.options.userMetadata)
        metadata.storageClass = stored.options.storageClass
        return metadata
    }

    func getObject(bucket: String, key: String, versionID: String?, range: ByteRange?, maxBytes: Int) async throws -> ObjectData {
        guard let stored = object(bucket, key) else { throw StorageError(kind: .service, code: "NoSuchKey", message: "missing", statusCode: 404) }
        let metadata = try await headObject(bucket: bucket, key: key, versionID: versionID)
        return ObjectData(data: stored.data.prefix(maxBytes), metadata: metadata, totalSize: Int64(stored.data.count))
    }

    func downloadObject(bucket: String, key: String, versionID: String?, range: ByteRange?, ifMatch: String?,
                        descriptor: Int32, fileOffset: Int64, progress: TransferProgressHandler?) async throws -> ObjectMetadata {
        record("downloadObject")
        if let range { try await rangeHook(range) }
        try Task.checkCancellation()
        guard let stored = object(bucket, key) else { throw StorageError(kind: .service, code: "NoSuchKey", message: "missing", statusCode: 404) }
        if let ifMatch, ifMatch != stored.eTag {
            throw StorageError(kind: .service, code: "PreconditionFailed", message: "changed", statusCode: 412)
        }
        let slice: Data
        if let range {
            state.withLock { $0.downloadedRanges.append(range) }
            slice = stored.data.subdata(in: Int(range.first)..<Int(min(range.last + 1, Int64(stored.data.count))))
        } else {
            slice = stored.data
        }
        if let error = TaskRouter.write(slice, to: descriptor, at: fileOffset) { throw error }
        progress?(Int64(slice.count))
        return try await headObject(bucket: bucket, key: key, versionID: versionID)
    }

    func putObject(bucket: String, key: String, body: Data, options: ObjectWriteOptions,
                   progress: TransferProgressHandler?) async throws -> PutResult {
        record("putObject")
        store(bucket, key, body, options: options)
        progress?(Int64(body.count))
        return PutResult(eTag: object(bucket, key)?.eTag)
    }

    func deleteObject(bucket: String, key: String, versionID: String?) async throws {
        record("deleteObject")
        _ = state.withLock { $0.objects.removeValue(forKey: Self.id(bucket, key)) }
    }

    func deleteObjects(bucket: String, objects: [ObjectReference]) async throws -> DeleteResult {
        record("deleteObjects")
        state.withLock { state in for object in objects { state.objects.removeValue(forKey: Self.id(bucket, object.key)) } }
        return DeleteResult(deleted: objects)
    }

    func copyObject(_ request: CopyObjectRequest) async throws -> PutResult {
        record("copyObject")
        guard let source = object(request.sourceBucket, request.sourceKey) else {
            throw StorageError(kind: .service, code: "NoSuchKey", message: "missing", statusCode: 404)
        }
        guard Int64(source.data.count) <= maxCopy else {
            throw StorageError(kind: .service, code: "InvalidRequest", message: "too large", statusCode: 400)
        }
        store(request.destinationBucket, request.destinationKey, source.data, options: request.directive == .replace ? request.options : source.options)
        return PutResult(eTag: object(request.destinationBucket, request.destinationKey)?.eTag)
    }

    func getObjectTags(bucket: String, key: String, versionID: String?) async throws -> [ObjectTag] { [] }
    func putObjectTags(bucket: String, key: String, versionID: String?, tags: [ObjectTag]) async throws {}

    func createMultipartUpload(bucket: String, key: String, options: ObjectWriteOptions) async throws -> String {
        record("createMultipartUpload")
        return state.withLock { state in
            let id = "upload-\(state.nextUploadID)"
            state.nextUploadID += 1
            state.uploads[id] = Upload(bucket: bucket, key: key, options: options, parts: [:])
            return id
        }
    }

    func uploadPart(bucket: String, key: String, uploadID: String, partNumber: Int, body: Data,
                    progress: TransferProgressHandler?) async throws -> UploadedPart {
        record("uploadPart")
        state.withLock { state in
            state.activeParts += 1
            state.maxActiveParts = max(state.maxActiveParts, state.activeParts)
        }
        defer { state.withLock { $0.activeParts -= 1 } }
        try await partHook(partNumber)
        try Task.checkCancellation()
        let eTag = "\"part-\(partNumber)-\(body.count)\""
        try state.withLock { state in
            guard state.uploads[uploadID] != nil else { throw StorageError(kind: .service, code: "NoSuchUpload", message: "gone", statusCode: 404) }
            state.uploads[uploadID]?.parts[partNumber] = (body, eTag)
            state.uploadedPartNumbers.append(partNumber)
        }
        progress?(Int64(body.count))
        return UploadedPart(partNumber: partNumber, eTag: eTag, size: Int64(body.count))
    }

    func uploadPartCopy(bucket: String, key: String, uploadID: String, partNumber: Int, sourceBucket: String,
                        sourceKey: String, sourceVersionID: String?, range: ByteRange) async throws -> UploadedPart {
        record("uploadPartCopy")
        guard let source = object(sourceBucket, sourceKey) else { throw StorageError(kind: .service, code: "NoSuchKey", message: "missing", statusCode: 404) }
        let slice = source.data.subdata(in: Int(range.first)..<Int(range.last + 1))
        let eTag = "\"copy-\(partNumber)\""
        state.withLock { $0.uploads[uploadID]?.parts[partNumber] = (slice, eTag) }
        return UploadedPart(partNumber: partNumber, eTag: eTag, size: range.length)
    }

    func completeMultipartUpload(bucket: String, key: String, uploadID: String, parts: [UploadedPart]) async throws -> PutResult {
        record("completeMultipartUpload")
        let upload = try state.withLock { state -> Upload in
            guard let upload = state.uploads.removeValue(forKey: uploadID) else {
                throw StorageError(kind: .service, code: "NoSuchUpload", message: "gone", statusCode: 404)
            }
            return upload
        }
        var data = Data()
        for part in parts.sorted(by: { $0.partNumber < $1.partNumber }) {
            guard let stored = upload.parts[part.partNumber], stored.eTag == part.eTag else {
                throw StorageError(kind: .service, code: "InvalidPart", message: "bad part \(part.partNumber)", statusCode: 400)
            }
            data.append(stored.data)
        }
        store(bucket, key, data, options: upload.options)
        return PutResult(eTag: "\"multipart-\(parts.count)\"")
    }

    func abortMultipartUpload(bucket: String, key: String, uploadID: String) async throws {
        record("abortMultipartUpload")
        _ = state.withLock { $0.uploads.removeValue(forKey: uploadID) }
    }

    func listParts(bucket: String, key: String, uploadID: String) async throws -> [UploadedPart] {
        record("listParts")
        return state.withLock { state in
            (state.uploads[uploadID]?.parts ?? [:]).map { UploadedPart(partNumber: $0.key, eTag: $0.value.eTag, size: Int64($0.value.data.count)) }
        }
    }

    func bucketSetting(_ kind: BucketSettingKind, bucket: String) async throws -> BucketSettingDocument {
        BucketSettingDocument(kind: kind, state: .notConfigured)
    }

    func versioningStatus(bucket: String) async throws -> VersioningStatus { .unversioned }
    func setVersioning(bucket: String, enabled: Bool) async throws {}

    func presignedURL(bucket: String, key: String, versionID: String?, method: String, expires: Int,
                      responseContentDisposition: String?) async throws -> URL {
        URL(fileURLWithPath: "/presigned/\(bucket)/\(key)")
    }
}

enum TempFiles {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func randomData(_ count: Int, seed: UInt64 = 42) -> Data {
        var generator = SeededGenerator(seed: seed)
        var words = [UInt64](repeating: 0, count: count / 8 + 1)
        for index in words.indices { words[index] = generator.next() }
        return words.withUnsafeBytes { Data($0.prefix(count)) }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
