import Foundation
import os

/// Server-side copy of one object: CopyObject up to the provider's limit (S3 5 GiB, OSS 1 GiB), otherwise a
/// parallel UploadPartCopy multipart copy that carries the source metadata (multipart copies do not copy
/// metadata by themselves). A failed multipart copy is aborted.
public struct ServerSideCopier: Sendable {
    public let storage: any ObjectStorage
    public let concurrency: Int
    /// Part size for multipart copies.
    public let partSize: Int64

    public init(storage: any ObjectStorage, concurrency: Int = 4, partSize: Int64 = 512 << 20) {
        self.storage = storage
        self.concurrency = max(1, concurrency)
        self.partSize = max(PartPlan.minimumPartSize, partSize)
    }

    /// Copies `request`. `knownSize` avoids a HEAD when the caller already has the source size.
    public func copy(_ request: CopyObjectRequest, knownSize: Int64? = nil,
                     progress: TransferProgressHandler? = nil) async throws -> PutResult {
        let size: Int64
        var sourceMetadata: ObjectMetadata?
        if let knownSize {
            size = knownSize
        } else {
            let metadata = try await storage.headObject(bucket: request.sourceBucket, key: request.sourceKey, versionID: request.sourceVersionID)
            size = metadata.size
            sourceMetadata = metadata
        }
        if size <= storage.capabilities.maxSingleCopySize {
            let result = try await storage.copyObject(request)
            progress?(size)
            return result
        }

        // Multipart copy: metadata must be supplied explicitly.
        var options = request.options
        if request.directive == .copy {
            let metadata: ObjectMetadata
            if let sourceMetadata {
                metadata = sourceMetadata
            } else {
                metadata = try await storage.headObject(bucket: request.sourceBucket, key: request.sourceKey, versionID: request.sourceVersionID)
            }
            options = metadata.writeOptions
            if let storageClass = request.options.storageClass { options.storageClass = storageClass }
        }
        let plan = PartPlan(totalSize: size, preferredPartSize: partSize)
        guard !plan.exceedsLimits else { throw StorageError.invalidRequest("The object is too large to copy.") }
        let uploadID = try await storage.createMultipartUpload(bucket: request.destinationBucket, key: request.destinationKey, options: options)
        do {
            let parts = try await withThrowingTaskGroup(of: UploadedPart.self) { group -> [UploadedPart] in
                var next = 1
                func addNext() -> Bool {
                    guard next <= plan.partCount, let span = plan.range(ofPart: next),
                          let range = ByteRange(first: span.offset, last: span.offset + span.length - 1) else { return false }
                    let number = next
                    next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let part = try await storage.uploadPartCopy(bucket: request.destinationBucket, key: request.destinationKey, uploadID: uploadID,
                                                                    partNumber: number, sourceBucket: request.sourceBucket, sourceKey: request.sourceKey,
                                                                    sourceVersionID: request.sourceVersionID, range: range)
                        progress?(range.length)
                        return part
                    }
                    return true
                }
                for _ in 0..<concurrency where addNext() {}
                var collected: [UploadedPart] = []
                while let part = try await group.next() {
                    collected.append(part)
                    _ = addNext()
                }
                return collected
            }
            return try await storage.completeMultipartUpload(bucket: request.destinationBucket, key: request.destinationKey,
                                                             uploadID: uploadID, parts: parts)
        } catch {
            // Best effort cleanup, even when the copy was cancelled.
            try? await Task.detached { try await storage.abortMultipartUpload(bucket: request.destinationBucket, key: request.destinationKey, uploadID: uploadID) }.value
            throw error
        }
    }
}

/// Visits every object under a prefix page by page (no delimiter), so folder operations on millions of
/// keys use bounded memory.
public struct ObjectEnumerator: Sendable {
    public let storage: any ObjectStorage

    public init(storage: any ObjectStorage) {
        self.storage = storage
    }

    /// Calls `body` with each page of objects (≤ 1,000). Stops early when `body` returns false.
    public func forEachPage(bucket: String, prefix: String, body: ([ObjectEntry]) async throws -> Bool) async throws {
        var token: ListToken?
        repeat {
            try Task.checkCancellation()
            let page = try await storage.listObjects(ListObjectsRequest(bucket: bucket, prefix: prefix, delimiter: nil, token: token))
            if !page.objects.isEmpty, try await !body(page.objects) { return }
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil
    }

    /// Counts objects and bytes under `prefix`, reporting running totals.
    public func summarize(bucket: String, prefix: String, progress: @Sendable (Int, Int64) -> Void = { _, _ in }) async throws -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        try await forEachPage(bucket: bucket, prefix: prefix) { objects in
            count += objects.count
            for object in objects { bytes = bytes &+ max(0, object.size) }
            progress(count, bytes)
            return true
        }
        return (count, bytes)
    }
}
