import Foundation
import StorageKit

/// `TransferExecutor` over the StorageKit engines. One instance per account session; all its transfers
/// share `limiter`, which bounds in-flight parts/chunks (and therefore memory) across the whole queue.
public struct StorageTransferExecutor: TransferExecutor {
    public let storage: any ObjectStorage
    public let limiter: AsyncLimiter
    public let partSize: Int64
    public let partConcurrency: Int
    public let downloadChunkSize: Int64

    public init(storage: any ObjectStorage, limiter: AsyncLimiter = AsyncLimiter(limit: 8), partSize: Int64 = 8 << 20,
                partConcurrency: Int = 4, downloadChunkSize: Int64 = 8 << 20) {
        self.storage = storage
        self.limiter = limiter
        self.partSize = partSize
        self.partConcurrency = partConcurrency
        self.downloadChunkSize = downloadChunkSize
    }

    public func execute(_ item: TransferItem, checkpoint: UploadCheckpoint?, progress: @escaping TransferProgressHandler,
                        onCheckpoint: @escaping @Sendable (UploadCheckpoint) -> Void) async throws {
        switch item.kind {
        case let .upload(file, bucket, key, options):
            _ = try await ObjectUploader(storage: storage, limiter: limiter, partConcurrency: partConcurrency)
                .upload(file: file, bucket: bucket, key: key, options: options, partSize: partSize, checkpoint: checkpoint,
                        progress: progress, onCheckpoint: onCheckpoint)
        case let .download(bucket, key, versionID, destination):
            try await ObjectDownloader(storage: storage, limiter: limiter, chunkSize: downloadChunkSize, concurrency: partConcurrency)
                .download(bucket: bucket, key: key, versionID: versionID, to: destination, progress: progress)
        case let .copy(request, size, deleteSource):
            _ = try await ServerSideCopier(storage: storage, concurrency: partConcurrency).copy(request, knownSize: size, progress: progress)
            let sameObject = request.sourceBucket == request.destinationBucket && request.sourceKey == request.destinationKey
            if deleteSource, !sameObject {
                try Task.checkCancellation()
                try await storage.deleteObject(bucket: request.sourceBucket, key: request.sourceKey, versionID: request.sourceVersionID)
            }
        case let .delete(bucket, objects):
            let result = try await storage.deleteObjects(bucket: bucket, objects: objects)
            progress(Int64(result.deleted.count))
            if let first = result.failures.first {
                throw StorageError(kind: .service, code: first.code,
                                   message: "\(result.failures.count.formatted()) objects could not be deleted (first: “\(first.key)”: \(first.message))")
            }
        }
    }

    public func discard(_ item: TransferItem, checkpoint: UploadCheckpoint?) async {
        switch item.kind {
        case .upload:
            if let checkpoint {
                try? await storage.abortMultipartUpload(bucket: checkpoint.bucket, key: checkpoint.key, uploadID: checkpoint.uploadID)
            }
        case let .download(_, _, _, destination):
            ObjectDownloader.discardPartial(for: destination)
        case .copy, .delete:
            break
        }
    }
}
