import Foundation
import os

/// Everything needed to resume a multipart upload (persistable).
public struct UploadCheckpoint: Codable, Sendable, Hashable {
    public var bucket: String
    public var key: String
    public var uploadID: String
    public var partSize: Int64
    public var fileSize: Int64
    public var fileModification: Date?
    public var parts: [UploadedPart]

    public init(bucket: String, key: String, uploadID: String, partSize: Int64, fileSize: Int64, fileModification: Date?, parts: [UploadedPart]) {
        self.bucket = bucket
        self.key = key
        self.uploadID = uploadID
        self.partSize = partSize
        self.fileSize = fileSize
        self.fileModification = fileModification
        self.parts = parts
    }

    public var uploadedBytes: Int64 { parts.reduce(0) { $0 + $1.size } }
}

/// Uploads one local file: a single PUT for small files, otherwise a parallel multipart upload whose memory
/// use is bounded by part size × the slots of the shared `AsyncLimiter`.
///
/// Pause = cancel the calling task and keep the last checkpoint. Resume = call `upload` again with it
/// (completed parts are re-validated with ListParts and skipped). Cancel = `abort(checkpoint)`.
public struct ObjectUploader: Sendable {
    /// Parts are held in memory while they are sent; larger parts would not fit comfortably (S3 objects are at
    /// most 5 TiB, which needs parts of about 525 MiB).
    public static let maximumInMemoryPartSize: Int64 = 1 << 30

    public let storage: any ObjectStorage
    public let limiter: AsyncLimiter
    public let partConcurrency: Int
    /// Bytes of part data per limiter unit.
    public let unitBytes: Int64

    public init(storage: any ObjectStorage, limiter: AsyncLimiter, partConcurrency: Int = 4, unitBytes: Int64 = 8 << 20) {
        self.storage = storage
        self.limiter = limiter
        self.partConcurrency = max(1, partConcurrency)
        self.unitBytes = max(1, unitBytes)
    }

    func units(for length: Int64) -> Int {
        Int(min(Int64(limiter.limit), max(1, (length + unitBytes - 1) / unitBytes)))
    }

    public func upload(file: URL, bucket: String, key: String, options: ObjectWriteOptions, partSize: Int64,
                       checkpoint: UploadCheckpoint? = nil, progress: @escaping TransferProgressHandler,
                       onCheckpoint: @escaping @Sendable (UploadCheckpoint) -> Void) async throws -> PutResult {
        let reader = try LocalFileReader(url: file)
        let plan = PartPlan(totalSize: reader.size, preferredPartSize: partSize)
        guard !plan.exceedsLimits, plan.partSize <= Self.maximumInMemoryPartSize else {
            throw StorageError.invalidRequest("“\(file.lastPathComponent)” is too large to upload (more than 10 TiB).")
        }

        guard plan.usesMultipart else {
            let storage = storage
            let size = reader.size
            // The body stays in memory until the PUT finishes, so it holds its limiter units that long.
            return try await limiter.withSlots(units(for: size)) {
                let body = try reader.read(offset: 0, length: size)
                return try await storage.putObject(bucket: bucket, key: key, body: body, options: options, progress: progress)
            }
        }

        var state: UploadCheckpoint
        if let checkpoint, checkpoint.bucket == bucket, checkpoint.key == key, checkpoint.fileSize == reader.size,
           checkpoint.partSize == plan.partSize, Self.sameDate(checkpoint.fileModification, reader.modificationDate) {
            state = checkpoint
            // The server is the source of truth: keep only parts it has, with the planned size.
            do {
                let listed = try await storage.listParts(bucket: bucket, key: key, uploadID: checkpoint.uploadID)
                state.parts = listed.filter { part in plan.range(ofPart: part.partNumber).map { $0.length == part.size } ?? false }
            } catch let error as StorageError where error.isNotFound {
                // The upload was aborted meanwhile (by a lifecycle rule or the user): start a new one.
                let uploadID = try await storage.createMultipartUpload(bucket: bucket, key: key, options: options)
                state = UploadCheckpoint(bucket: bucket, key: key, uploadID: uploadID, partSize: plan.partSize, fileSize: reader.size,
                                         fileModification: reader.modificationDate, parts: [])
            }
        } else {
            if let checkpoint, checkpoint.bucket == bucket, checkpoint.key == key {
                // The file changed since the pause: the old parts are useless.
                try? await storage.abortMultipartUpload(bucket: bucket, key: key, uploadID: checkpoint.uploadID)
            }
            let uploadID = try await storage.createMultipartUpload(bucket: bucket, key: key, options: options)
            state = UploadCheckpoint(bucket: bucket, key: key, uploadID: uploadID, partSize: plan.partSize, fileSize: reader.size,
                                     fileModification: reader.modificationDate, parts: [])
        }
        onCheckpoint(state)
        if state.uploadedBytes > 0 { progress(state.uploadedBytes) }

        let done = Set(state.parts.map(\.partNumber))
        let pending = (1...plan.partCount).filter { !done.contains($0) }
        let collected = OSAllocatedUnfairLock(initialState: state)
        let uploadID = state.uploadID

        try await withThrowingTaskGroup(of: UploadedPart.self) { group in
            var iterator = pending.makeIterator()
            func addNext() -> Bool {
                guard let number = iterator.next(), let range = plan.range(ofPart: number) else { return false }
                let units = units(for: range.length)
                group.addTask {
                    try await limiter.withSlots(units) {
                        try Task.checkCancellation()
                        let body = try reader.read(offset: range.offset, length: range.length)
                        return try await storage.uploadPart(bucket: bucket, key: key, uploadID: uploadID, partNumber: number,
                                                            body: body, progress: progress)
                    }
                }
                return true
            }
            for _ in 0..<partConcurrency where addNext() {}
            while let part = try await group.next() {
                let snapshot = collected.withLock { current -> UploadCheckpoint in
                    current.parts.append(part)
                    return current
                }
                onCheckpoint(snapshot)
                _ = addNext()
            }
        }

        let parts = collected.withLock { $0.parts }.sorted { $0.partNumber < $1.partNumber }
        guard parts.count == plan.partCount else {
            throw StorageError.invalidResponse("Only \(parts.count) of \(plan.partCount) parts were uploaded.")
        }
        try Task.checkCancellation()
        do {
            return try await storage.completeMultipartUpload(bucket: bucket, key: key, uploadID: uploadID, parts: parts)
        } catch let error as StorageError where error.code == "NoSuchUpload" {
            // A retried Complete whose first attempt succeeded: the object exists with the expected size and part count.
            if let existing = try? await storage.headObject(bucket: bucket, key: key, versionID: nil), existing.size == reader.size,
               existing.eTag?.hasSuffix("-\(parts.count)\"") ?? false {
                return PutResult(eTag: existing.eTag, versionID: existing.versionID)
            }
            throw error
        }
    }

    /// Releases the parts of an unfinished upload.
    public func abort(_ checkpoint: UploadCheckpoint) async throws {
        try await storage.abortMultipartUpload(bucket: checkpoint.bucket, key: checkpoint.key, uploadID: checkpoint.uploadID)
    }

    static func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): abs(left.timeIntervalSince(right)) < 0.001
        default: false
        }
    }
}
