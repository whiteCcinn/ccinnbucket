import Foundation
import os
@testable import StorageKit
import Testing

@Suite("Engines: part planning, uploads, downloads, copies")
struct EngineTests {
    private static let mib: Int64 = 1 << 20

    @Test("part plans respect the 5 MiB minimum and 10,000-part maximum")
    func partPlans() {
        let small = PartPlan(totalSize: 300 * Self.mib, preferredPartSize: 5 * Self.mib)
        #expect(small.usesMultipart)
        #expect(small.partCount == 60)
        #expect(small.range(ofPart: 60)?.length == 5 * Self.mib)
        let uneven = PartPlan(totalSize: 12 * Self.mib + 123, preferredPartSize: 5 * Self.mib)
        #expect(uneven.partCount == 3)
        #expect(uneven.range(ofPart: 3)?.length == 2 * Self.mib + 123)
        #expect(uneven.range(ofPart: 4) == nil)
        #expect(uneven.range(ofPart: 0) == nil)
        let huge = PartPlan(totalSize: 100 << 30, preferredPartSize: 5 * Self.mib)
        #expect(huge.partCount <= 10_000)
        #expect(huge.partSize % Self.mib == 0)
        #expect(Int64(huge.partCount) * huge.partSize >= 100 << 30)
        let tooSmallPreference = PartPlan(totalSize: 50 * Self.mib, preferredPartSize: 1)
        #expect(tooSmallPreference.partSize == 5 * Self.mib)
        #expect(PartPlan(totalSize: 5 * Self.mib, preferredPartSize: 5 * Self.mib).usesMultipart == false)
        #expect(PartPlan(totalSize: 5 * Self.mib + 1, preferredPartSize: 5 * Self.mib).partCount == 2)
        #expect(PartPlan(totalSize: 0, preferredPartSize: 0).partCount == 0)
        #expect(PartPlan(totalSize: -5, preferredPartSize: -5).partCount == 0)
        #expect(PartPlan(totalSize: 60 << 40, preferredPartSize: 0).exceedsLimits)
        #expect(PartPlan(totalSize: Int64.max, preferredPartSize: Int64.max).exceedsLimits)
        let chunks = PartPlan.chunks(totalSize: 3 * Self.mib + 7, chunkSize: Self.mib)
        #expect(chunks.count == 4)
        #expect(chunks.last == ByteRange(first: 3 * Self.mib, last: 3 * Self.mib + 6))
        #expect(PartPlan.chunks(totalSize: 0, chunkSize: Self.mib).isEmpty)
    }

    @Test("multipart upload reassembles the file exactly; memory slots bound parallelism")
    func multipartUpload() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("big.bin")
        let content = TempFiles.randomData(Int(12 * Self.mib + 123))
        try content.write(to: file)
        let storage = InMemoryStorage(partHook: { _ in try await Task.sleep(nanoseconds: 20_000_000) })
        let uploader = ObjectUploader(storage: storage, limiter: AsyncLimiter(limit: 2), partConcurrency: 4)
        let progress = OSAllocatedUnfairLock<Int64>(initialState: 0)
        let checkpoints = OSAllocatedUnfairLock<[UploadCheckpoint]>(initialState: [])
        _ = try await uploader.upload(file: file, bucket: "b", key: "big.bin", options: ObjectWriteOptions(contentType: "application/x-test"),
                                      partSize: 5 * Self.mib, progress: { delta in progress.withLock { $0 += delta } },
                                      onCheckpoint: { checkpoint in checkpoints.withLock { $0.append(checkpoint) } })
        #expect(storage.object("b", "big.bin")?.data == content)
        #expect(storage.object("b", "big.bin")?.options.contentType == "application/x-test")
        #expect(storage.count("uploadPart") == 3)
        #expect(storage.state.withLock { $0.maxActiveParts } <= 2)
        #expect(progress.withLock { $0 } == Int64(content.count))
        #expect(checkpoints.withLock { $0.last?.parts.count } == 3)
    }

    @Test("small files use a single PUT")
    func singlePut() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("small.txt")
        try Data("hello".utf8).write(to: file)
        let storage = InMemoryStorage()
        _ = try await ObjectUploader(storage: storage, limiter: AsyncLimiter(limit: 4)).upload(
            file: file, bucket: "b", key: "small.txt", options: ObjectWriteOptions(), partSize: 5 * Self.mib, progress: { _ in }, onCheckpoint: { _ in })
        #expect(storage.count("putObject") == 1)
        #expect(storage.count("createMultipartUpload") == 0)
        #expect(storage.object("b", "small.txt")?.data == Data("hello".utf8))
    }

    @Test("pause and resume uploads only the missing parts")
    func pauseResume() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("resume.bin")
        let content = TempFiles.randomData(Int(20 * Self.mib), seed: 7)
        try content.write(to: file)
        let blockPart3 = OSAllocatedUnfairLock(initialState: true)
        let storage = InMemoryStorage(partHook: { number in
            if number >= 3, blockPart3.withLock({ $0 }) {
                try await Task.sleep(nanoseconds: 60_000_000_000) // until cancelled (the "pause")
            }
        })
        let uploader = ObjectUploader(storage: storage, limiter: AsyncLimiter(limit: 8), partConcurrency: 2)
        let latest = OSAllocatedUnfairLock<UploadCheckpoint?>(initialState: nil)
        let task = Task {
            try await uploader.upload(file: file, bucket: "b", key: "r.bin", options: ObjectWriteOptions(), partSize: 5 * Self.mib,
                                      progress: { _ in }, onCheckpoint: { checkpoint in latest.withLock { $0 = checkpoint } })
        }
        for _ in 0..<200 where (latest.withLock { $0?.parts.count } ?? 0) < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel() // pause
        _ = await task.result
        let checkpoint = try #require(latest.withLock { $0 })
        #expect(checkpoint.parts.count == 2)
        #expect(storage.object("b", "r.bin") == nil)

        blockPart3.withLock { $0 = false }
        let before = storage.state.withLock { $0.uploadedPartNumbers }
        _ = try await uploader.upload(file: file, bucket: "b", key: "r.bin", options: ObjectWriteOptions(), partSize: 5 * Self.mib,
                                      checkpoint: checkpoint, progress: { _ in }, onCheckpoint: { _ in })
        let after = storage.state.withLock { $0.uploadedPartNumbers }
        #expect(Set(after.dropFirst(before.count)) == [3, 4])
        #expect(storage.count("createMultipartUpload") == 1)
        #expect(storage.count("listParts") == 1)
        #expect(storage.object("b", "r.bin")?.data == content)
    }

    @Test("resuming after the file changed aborts the stale upload and starts over")
    func resumeChangedFile() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("changed.bin")
        try TempFiles.randomData(Int(11 * Self.mib)).write(to: file)
        let storage = InMemoryStorage()
        let uploader = ObjectUploader(storage: storage, limiter: AsyncLimiter(limit: 4))
        let staleID = try await storage.createMultipartUpload(bucket: "b", key: "c.bin", options: ObjectWriteOptions())
        let stale = UploadCheckpoint(bucket: "b", key: "c.bin", uploadID: staleID, partSize: 5 * Self.mib, fileSize: 1, fileModification: nil, parts: [])
        _ = try await uploader.upload(file: file, bucket: "b", key: "c.bin", options: ObjectWriteOptions(), partSize: 5 * Self.mib,
                                      checkpoint: stale, progress: { _ in }, onCheckpoint: { _ in })
        #expect(storage.count("abortMultipartUpload") == 1)
        #expect(storage.count("createMultipartUpload") == 2)
        #expect(storage.object("b", "c.bin")?.data.count == Int(11 * Self.mib))
    }

    @Test("downloads stream ranges into a partial file and rename it only when complete")
    func download() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = TempFiles.randomData(Int(3 * Self.mib + 517), seed: 3)
        let storage = InMemoryStorage()
        storage.store("b", "dir/file.bin", content)
        let destination = directory.appendingPathComponent("file.bin")
        let progress = OSAllocatedUnfairLock<Int64>(initialState: 0)
        try await ObjectDownloader(storage: storage, limiter: AsyncLimiter(limit: 3), chunkSize: Self.mib, concurrency: 3)
            .download(bucket: "b", key: "dir/file.bin", versionID: nil, to: destination, progress: { delta in progress.withLock { $0 += delta } })
        #expect(try Data(contentsOf: destination) == content)
        #expect(progress.withLock { $0 } == Int64(content.count))
        #expect(!FileManager.default.fileExists(atPath: ObjectDownloader.partialURL(for: destination).path))
        #expect(!FileManager.default.fileExists(atPath: ObjectDownloader.sidecarURL(for: destination).path))
        #expect(storage.state.withLock { $0.downloadedRanges.count } == 4)

        // Empty objects produce empty files.
        storage.store("b", "empty", Data())
        let empty = directory.appendingPathComponent("empty")
        try await ObjectDownloader(storage: storage, limiter: AsyncLimiter(limit: 1)).download(bucket: "b", key: "empty", versionID: nil, to: empty, progress: { _ in })
        #expect(try Data(contentsOf: empty).isEmpty)
    }

    @Test("an interrupted download resumes with only the missing ranges")
    func downloadResume() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let content = TempFiles.randomData(Int(4 * Self.mib), seed: 11)
        let block = OSAllocatedUnfairLock(initialState: true)
        let storage = InMemoryStorage(rangeHook: { range in
            if range.first >= 2 * (1 << 20), block.withLock({ $0 }) { try await Task.sleep(nanoseconds: 60_000_000_000) }
        })
        storage.store("b", "k", content)
        let destination = directory.appendingPathComponent("k.bin")
        let downloader = ObjectDownloader(storage: storage, limiter: AsyncLimiter(limit: 4), chunkSize: Self.mib, concurrency: 2)
        let task = Task { try await downloader.download(bucket: "b", key: "k", versionID: nil, to: destination, progress: { _ in }) }
        for _ in 0..<300 {
            if let data = try? Data(contentsOf: ObjectDownloader.sidecarURL(for: destination)),
               let saved = try? JSONDecoder().decode(DownloadCheckpoint.self, from: data), saved.completed.count >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        _ = await task.result
        #expect(FileManager.default.fileExists(atPath: ObjectDownloader.partialURL(for: destination).path))
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        block.withLock { $0 = false }
        let before = storage.state.withLock { $0.downloadedRanges.count }
        try await downloader.download(bucket: "b", key: "k", versionID: nil, to: destination, progress: { _ in })
        let fetched = storage.state.withLock { Array($0.downloadedRanges.dropFirst(before)) }
        #expect(fetched.map(\.first).sorted() == [2 * Self.mib, 3 * Self.mib])
        #expect(try Data(contentsOf: destination) == content)
    }

    @Test("a changed object (412) discards the partial download")
    func downloadPrecondition() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = InMemoryStorage(rangeHook: { range in
            if range.first > 0 { throw StorageError(kind: .service, code: "PreconditionFailed", message: "changed", statusCode: 412) }
        })
        storage.store("b", "k", TempFiles.randomData(Int(2 * Self.mib + 5)))
        let destination = directory.appendingPathComponent("k")
        await #expect(throws: StorageError.self) {
            try await ObjectDownloader(storage: storage, limiter: AsyncLimiter(limit: 2), chunkSize: Self.mib)
                .download(bucket: "b", key: "k", versionID: nil, to: destination, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: ObjectDownloader.partialURL(for: destination).path))
        #expect(!FileManager.default.fileExists(atPath: ObjectDownloader.sidecarURL(for: destination).path))
    }

    @Test("copies above the single-copy limit use multipart copy with the source metadata")
    func multipartCopy() async throws {
        let storage = InMemoryStorage(maxSingleCopySize: 6 * Self.mib)
        let content = TempFiles.randomData(Int(13 * Self.mib))
        storage.store("src", "big", content, options: ObjectWriteOptions(contentType: "video/mp4", userMetadata: ["owner": "ccinn"]))
        let copier = ServerSideCopier(storage: storage, concurrency: 2, partSize: 5 * Self.mib)
        _ = try await copier.copy(CopyObjectRequest(sourceBucket: "src", sourceKey: "big", destinationBucket: "dst", destinationKey: "big-copy"))
        #expect(storage.count("copyObject") == 0)
        #expect(storage.count("uploadPartCopy") == 3)
        #expect(storage.object("dst", "big-copy")?.data == content)
        #expect(storage.object("dst", "big-copy")?.options.contentType == "video/mp4")
        #expect(storage.object("dst", "big-copy")?.options.userMetadata == ["owner": "ccinn"])

        storage.store("src", "small", Data("abc".utf8))
        _ = try await copier.copy(CopyObjectRequest(sourceBucket: "src", sourceKey: "small", destinationBucket: "dst", destinationKey: "small"))
        #expect(storage.count("copyObject") == 1)
    }

    @Test("enumerator visits every page and can stop early")
    func enumerator() async throws {
        let storage = InMemoryStorage()
        for index in 0..<2_345 { storage.store("b", String(format: "logs/%05d", index), Data([1])) }
        storage.store("b", "other/x", Data([1]))
        let summary = try await ObjectEnumerator(storage: storage).summarize(bucket: "b", prefix: "logs/")
        #expect(summary.count == 2_345)
        #expect(summary.bytes == 2_345)
        var pages = 0
        try await ObjectEnumerator(storage: storage).forEachPage(bucket: "b", prefix: "logs/") { _ in
            pages += 1
            return pages < 2
        }
        #expect(pages == 2)
    }

    @Test("limiter is FIFO and cancellation-safe")
    func limiter() async throws {
        let limiter = AsyncLimiter(limit: 1)
        try await limiter.acquire()
        let waiter = Task { try await limiter.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await limiter.release()
        try await limiter.acquire()
        #expect(await limiter.inUse == 1)
        await limiter.release()
        #expect(await limiter.inUse == 0)
    }
}
