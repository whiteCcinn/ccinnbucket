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

    /// Larger sizes reported by a server are treated as bogus (protects allocation and arithmetic).
    public static let maximumObjectSize: Int64 = 50 << 40

    /// Removes leftovers of an interrupted download (used when the user cancels instead of pausing).
    /// Leftovers that a running download holds (locked) are never touched.
    public static func discardPartial(for destination: URL) {
        let partial = partialURL(for: destination)
        let descriptor = open(partial.path, O_RDWR | O_CLOEXEC)
        if descriptor >= 0 {
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
            unlink(partial.path)
            unlink(sidecarURL(for: destination).path)
        } else {
            unlink(sidecarURL(for: destination).path)
        }
    }

    /// Downloads `key` to `destination` (replacing an existing file only after a complete download).
    @discardableResult
    public func download(bucket: String, key: String, versionID: String?, to destination: URL,
                         progress: @escaping TransferProgressHandler) async throws -> ObjectMetadata {
        let metadata = try await storage.headObject(bucket: bucket, key: key, versionID: versionID)
        if metadata.isDeleteMarker { throw StorageError.invalidRequest("“\(key)” is a delete marker and has no content.") }
        let size = metadata.size
        guard (0...Self.maximumObjectSize).contains(size) else {
            throw StorageError.invalidResponse("The server reported an implausible size (\(size) bytes) for “\(key)”.")
        }
        let partial = Self.partialURL(for: destination)
        let sidecar = Self.sidecarURL(for: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let descriptor = open(partial.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw StorageError.localFile("Could not create “\(partial.lastPathComponent)”: \(String(cString: strerror(errno))).")
        }
        defer { close(descriptor) }
        // One writer per destination: a second download of the same file fails instead of corrupting it.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw StorageError.localFile("Another download is already writing “\(destination.lastPathComponent)”. Wait for it to finish or choose another folder.")
        }

        var checkpoint = DownloadCheckpoint(bucket: bucket, key: key, versionID: versionID, eTag: metadata.eTag, size: size,
                                            chunkSize: chunkSize, completed: [])
        var info = stat()
        let partialSize = fstat(descriptor, &info) == 0 ? Int64(info.st_size) : -1
        if let data = try? Data(contentsOf: sidecar), data.count < 4 << 20,
           let saved = try? JSONDecoder().decode(DownloadCheckpoint.self, from: data),
           saved.bucket == bucket, saved.key == key, saved.versionID == versionID, saved.eTag == metadata.eTag, saved.size == size,
           saved.chunkSize == chunkSize, partialSize == size {
            checkpoint = saved
        } else {
            unlink(sidecar.path)
            guard ftruncate(descriptor, 0) == 0 else {
                throw StorageError.localFile("Could not reset “\(partial.lastPathComponent)”: \(String(cString: strerror(errno))).")
            }
        }
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
                    // Data first, then the record that it is there: a crash never leaves a "completed" chunk unwritten.
                    _ = fsync(descriptor)
                    let snapshot = state.withLock { current -> DownloadCheckpoint in
                        current.completed.append(index)
                        return current
                    }
                    await writer.write(snapshot)
                    _ = addNext()
                }
            }
        } catch let error as StorageError where error.statusCode == 412 || error.code == "PreconditionFailed" {
            await writer.finish()
            unlink(partial.path)
            unlink(sidecar.path)
            throw StorageError(kind: .service, code: "PreconditionFailed",
                               message: "“\(key)” changed on the server during the download. Start the download again.", statusCode: 412)
        }

        guard fsync(descriptor) == 0 else { throw StorageError.localFile("Could not flush the downloaded file to disk.") }
        if let modified = metadata.lastModified {
            let seconds = SigningTime.unixSeconds(modified)
            var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
            _ = futimens(descriptor, &times)
        }
        // Only move the file we actually wrote (the path could have been replaced meanwhile).
        var onDisk = stat()
        var ours = stat()
        guard stat(partial.path, &onDisk) == 0, fstat(descriptor, &ours) == 0, onDisk.st_ino == ours.st_ino, onDisk.st_dev == ours.st_dev else {
            throw StorageError.localFile("“\(partial.lastPathComponent)” was replaced while downloading; the download was not saved.")
        }
        guard rename(partial.path, destination.path) == 0 else {
            throw StorageError.localFile("Could not move the download into place: \(String(cString: strerror(errno))).")
        }
        await writer.finish()
        unlink(sidecar.path)
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
