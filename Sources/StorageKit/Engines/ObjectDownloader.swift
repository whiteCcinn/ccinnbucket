import Foundation
import os
import StorageSigning

/// Sidecar describing a partially downloaded object, stored next to the partial file.
public struct DownloadCheckpoint: Codable, Sendable, Hashable {
    public var version = 1
    public var bucket: String
    public var key: String
    public var versionID: String?
    public var eTag: String?
    public var size: Int64
    public var chunkSize: Int64
    public var completed: [Int]
}

/// Streams objects to disk with constant memory: one GET for small objects, parallel ranged GETs (each
/// written in place with `pwrite`) for large ones. Data goes to `<name>.ccinnbucket-partial`, which is
/// renamed over the destination only when every byte has arrived. A sidecar records finished chunks so an
/// interrupted (paused, failed, quit) download resumes; `If-Match` guarantees all chunks come from the same
/// object version.
public struct ObjectDownloader: Sendable {
    public static let partialSuffix = ".ccinnbucket-partial"
    public static let sidecarSuffix = ".ccinnbucket-partial.json"

    public let storage: any ObjectStorage
    public let limiter: AsyncLimiter
    public let chunkSize: Int64
    public let concurrency: Int

    public init(storage: any ObjectStorage, limiter: AsyncLimiter, chunkSize: Int64 = 8 << 20, concurrency: Int = 4) {
        self.storage = storage
        self.limiter = limiter
        self.chunkSize = max(1 << 20, chunkSize)
        self.concurrency = max(1, concurrency)
    }

    public static func partialURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + partialSuffix)
    }

    public static func sidecarURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + sidecarSuffix)
    }

    /// Removes leftovers of an interrupted download (used when the user cancels instead of pausing).
    public static func discardPartial(for destination: URL) {
        try? FileManager.default.removeItem(at: partialURL(for: destination))
        try? FileManager.default.removeItem(at: sidecarURL(for: destination))
    }

    /// Downloads `key` to `destination` (replacing an existing file only after a complete download).
    @discardableResult
    public func download(bucket: String, key: String, versionID: String?, to destination: URL,
                         progress: @escaping TransferProgressHandler) async throws -> ObjectMetadata {
        let metadata = try await storage.headObject(bucket: bucket, key: key, versionID: versionID)
        if metadata.isDeleteMarker { throw StorageError.invalidRequest("“\(key)” is a delete marker and has no content.") }
        let size = metadata.size
        let partial = Self.partialURL(for: destination)
        let sidecar = Self.sidecarURL(for: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var checkpoint = DownloadCheckpoint(bucket: bucket, key: key, versionID: versionID, eTag: metadata.eTag, size: size,
                                            chunkSize: chunkSize, completed: [])
        if let data = try? Data(contentsOf: sidecar), data.count < 4 << 20,
           let saved = try? JSONDecoder().decode(DownloadCheckpoint.self, from: data),
           saved.bucket == bucket, saved.key == key, saved.versionID == versionID, saved.eTag == metadata.eTag, saved.size == size,
           saved.chunkSize == chunkSize, (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ Int64($0) == size }) == true {
            checkpoint = saved
        } else {
            Self.discardPartial(for: destination)
        }

        let descriptor = open(partial.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw StorageError.localFile("Could not create “\(partial.lastPathComponent)”: \(String(cString: strerror(errno))).")
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(size)) == 0 else {
            throw StorageError.localFile("Could not reserve \(size) bytes on disk: \(String(cString: strerror(errno))).")
        }

        let chunks = size <= chunkSize ? (size > 0 ? [ByteRange(first: 0, last: size - 1)].compactMap { $0 } : [])
            : PartPlan.chunks(totalSize: size, chunkSize: chunkSize)
        let completed = Set(checkpoint.completed.filter { chunks.indices.contains($0) })
        let alreadyDone = completed.reduce(Int64(0)) { $0 + chunks[$1].length }
        if alreadyDone > 0 { progress(alreadyDone) }

        let state = OSAllocatedUnfairLock(initialState: checkpoint)
        let writer = CheckpointWriter(url: sidecar)
        let pending = chunks.indices.filter { !completed.contains($0) }
        let eTag = metadata.eTag

        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                var iterator = pending.makeIterator()
                func addNext() -> Bool {
                    guard let index = iterator.next() else { return false }
                    let range = chunks[index]
                    group.addTask {
                        try await limiter.withSlot {
                            try Task.checkCancellation()
                            // Always ranged + If-Match: every byte comes from the version the HEAD described.
                            _ = try await storage.downloadObject(bucket: bucket, key: key, versionID: versionID, range: range,
                                                                 ifMatch: eTag, descriptor: descriptor, fileOffset: range.first,
                                                                 progress: progress)
                            return index
                        }
                    }
                    return true
                }
                for _ in 0..<concurrency where addNext() {}
                while let index = try await group.next() {
                    let snapshot = state.withLock { current -> DownloadCheckpoint in
                        current.completed.append(index)
                        return current
                    }
                    await writer.write(snapshot)
                    _ = addNext()
                }
            }
        } catch let error as StorageError where error.statusCode == 412 || error.code == "PreconditionFailed" {
            Self.discardPartial(for: destination)
            throw StorageError(kind: .service, code: "PreconditionFailed",
                               message: "“\(key)” changed on the server during the download. Start the download again.", statusCode: 412)
        }

        guard fsync(descriptor) == 0 else { throw StorageError.localFile("Could not flush the downloaded file to disk.") }
        if let modified = metadata.lastModified {
            let seconds = SigningTime.unixSeconds(modified)
            var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
            _ = futimens(descriptor, &times)
        }
        guard rename(partial.path, destination.path) == 0 else {
            throw StorageError.localFile("Could not move the download into place: \(String(cString: strerror(errno))).")
        }
        await writer.finish()
        try? FileManager.default.removeItem(at: sidecar)
        return metadata
    }
}

/// Serialises sidecar writes (latest snapshot wins; atomic replace).
actor CheckpointWriter {
    private let url: URL
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    func write(_ checkpoint: DownloadCheckpoint) {
        guard !finished, let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func finish() { finished = true }
}
