import CcinnBucketKit
import Foundation
import os
import StorageKit
import Testing

/// Executor double: each item "transfers" its size in 4 steps; items named "fail*" fail, "slow*" wait until cancelled.
final class FakeExecutor: TransferExecutor {
    struct Log: Sendable {
        var started: [String] = []
        var finished: [String] = []
        var discarded: [String] = []
        var checkpointsSeen: [String: UploadCheckpoint] = [:]
        var running = 0
        var maxRunning = 0
    }

    let log = OSAllocatedUnfairLock(initialState: Log())
    let releaseSlow = OSAllocatedUnfairLock(initialState: false)

    func execute(_ item: TransferItem, checkpoint: UploadCheckpoint?, progress: @escaping TransferProgressHandler,
                 onCheckpoint: @escaping @Sendable (UploadCheckpoint) -> Void) async throws {
        let name = item.displayName
        log.withLock { log in
            log.started.append(name)
            log.running += 1
            log.maxRunning = max(log.maxRunning, log.running)
            if let checkpoint { log.checkpointsSeen[name] = checkpoint }
        }
        defer { log.withLock { $0.running -= 1 } }
        let step = item.size / 4
        let alreadyDone = checkpoint?.uploadedBytes ?? 0
        if alreadyDone > 0 { progress(alreadyDone) }
        if name.hasPrefix("slow") {
            progress(step)
            onCheckpoint(UploadCheckpoint(bucket: "b", key: name, uploadID: "u-\(name)", partSize: step, fileSize: item.size, fileModification: nil,
                                          parts: [UploadedPart(partNumber: 1, eTag: "e", size: step)]))
            while !releaseSlow.withLock({ $0 }) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            progress(item.size - step - alreadyDone)
        } else {
            for _ in 0..<4 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 2_000_000)
                progress(step)
            }
        }
        if name.hasPrefix("fail") { throw StorageError(kind: .service, code: "AccessDenied", message: "Access Denied", statusCode: 403) }
        log.withLock { $0.finished.append(name) }
    }

    func discard(_ item: TransferItem, checkpoint: UploadCheckpoint?) async {
        log.withLock { $0.discarded.append(item.displayName) }
    }
}

@Suite("Transfer queue")
struct TransferQueueTests {
    private static func upload(_ name: String, size: Int64 = 400) -> TransferItem {
        TransferItem(kind: .upload(file: URL(fileURLWithPath: "/tmp/\(name)"), bucket: "b", key: name, options: ObjectWriteOptions()), size: size)
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("condition not met in time")
    }

    @Test("jobs complete with exact byte and item totals")
    func completes() async throws {
        let executor = FakeExecutor()
        let queue = TransferQueue(executor: executor, maxConcurrentJobs: 2, itemConcurrency: 3)
        let id = await queue.enqueue(title: "site", direction: .upload, items: (0..<10).map { Self.upload("f\($0)") })
        try await Self.waitUntil { await queue.job(id)?.status == .completed }
        let job = try #require(await queue.job(id))
        #expect(job.transferredBytes == 4_000)
        #expect(job.totalBytes == 4_000)
        #expect(job.completedItems == 10)
        #expect(job.fractionCompleted == 1)
        #expect(executor.log.withLock { $0.maxRunning } <= 3)
    }

    @Test("concurrent jobs are bounded")
    func boundedJobs() async throws {
        let executor = FakeExecutor()
        let queue = TransferQueue(executor: executor, maxConcurrentJobs: 1, itemConcurrency: 1)
        let first = await queue.enqueue(title: "one", direction: .upload, items: [Self.upload("slow-1")])
        let second = await queue.enqueue(title: "two", direction: .upload, items: [Self.upload("f2")])
        try await Self.waitUntil { await queue.job(first)?.status == .running }
        #expect(await queue.job(second)?.status == .queued)
        executor.releaseSlow.withLock { $0 = true }
        try await Self.waitUntil { await queue.job(second)?.status == .completed }
    }

    @Test("pause keeps checkpoints; resume passes them back and finishes")
    func pauseResume() async throws {
        let executor = FakeExecutor()
        let queue = TransferQueue(executor: executor, maxConcurrentJobs: 2, itemConcurrency: 2)
        let id = await queue.enqueue(title: "big", direction: .upload, items: [Self.upload("slow-a"), Self.upload("f-b")])
        try await Self.waitUntil { executor.log.withLock { $0.finished.contains("f-b") && $0.started.contains("slow-a") } }
        await queue.pause(id)
        try await Self.waitUntil { await queue.job(id)?.status == .paused }
        #expect(executor.log.withLock { $0.discarded.isEmpty })
        executor.releaseSlow.withLock { $0 = true }
        await queue.resume(id)
        try await Self.waitUntil { await queue.job(id)?.status == .completed }
        #expect(executor.log.withLock { $0.checkpointsSeen["slow-a"]?.uploadID } == "u-slow-a")
        #expect(executor.log.withLock { $0.started.filter { $0 == "f-b" }.count } == 1, "finished items are not repeated")
        #expect(await queue.job(id)?.transferredBytes == 800)
    }

    @Test("cancel discards unfinished items (aborts multipart uploads)")
    func cancel() async throws {
        let executor = FakeExecutor()
        let queue = TransferQueue(executor: executor, maxConcurrentJobs: 1, itemConcurrency: 1)
        let id = await queue.enqueue(title: "c", direction: .upload, items: [Self.upload("slow-x")])
        try await Self.waitUntil { executor.log.withLock { $0.started.contains("slow-x") } }
        await queue.cancel(id)
        try await Self.waitUntil { await queue.job(id)?.status == .cancelled }
        try await Self.waitUntil { executor.log.withLock { $0.discarded == ["slow-x"] } }
    }

    @Test("failures are collected per item; retry re-runs only failed items")
    func failuresAndRetry() async throws {
        let executor = FakeExecutor()
        let queue = TransferQueue(executor: executor, maxConcurrentJobs: 1, itemConcurrency: 2)
        let id = await queue.enqueue(title: "mixed", direction: .upload, items: [Self.upload("ok-1"), Self.upload("fail-2"), Self.upload("ok-3")])
        try await Self.waitUntil { if case .failed = await queue.job(id)?.status { return true } else { return false } }
        let job = try #require(await queue.job(id))
        #expect(job.completedItems == 2)
        #expect(job.failures.map(\.name) == ["fail-2"])
        #expect(job.failures.first?.message.contains("Access Denied") == true)
        await queue.retry(id)
        try await Self.waitUntil { if case .failed = await queue.job(id)?.status { return true } else { return false } }
        #expect(executor.log.withLock { $0.started.filter { $0.hasPrefix("ok") }.count } == 2)
        #expect(executor.log.withLock { $0.started.filter { $0 == "fail-2" }.count } == 2)
    }

    @Test("clearing finished jobs keeps running and paused ones; aggregate snapshot sums rates")
    func clearAndSnapshot() async throws {
        let executor = FakeExecutor()
        let queue = TransferQueue(executor: executor, maxConcurrentJobs: 2, itemConcurrency: 1)
        let done = await queue.enqueue(title: "done", direction: .download, items: [Self.upload("f1")])
        let running = await queue.enqueue(title: "running", direction: .upload, items: [Self.upload("slow-r")])
        try await Self.waitUntil { await queue.job(done)?.status == .completed }
        await queue.clearFinished()
        let snapshot = await queue.snapshot()
        #expect(snapshot.jobs.map(\.id) == [running])
        #expect(snapshot.activeCount == 1)
        executor.releaseSlow.withLock { $0 = true }
        try await Self.waitUntil { await queue.job(running)?.status == .completed }
    }

    @Test("an empty job completes immediately")
    func emptyJob() async throws {
        let queue = TransferQueue(executor: FakeExecutor())
        let id = await queue.enqueue(title: "nothing", direction: .upload, items: [])
        try await Self.waitUntil { await queue.job(id)?.status == .completed }
    }
}
