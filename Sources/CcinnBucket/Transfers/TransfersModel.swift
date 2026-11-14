import CcinnBucketKit
import Foundation
import Observation
import StorageKit

/// Main-actor mirror of the `TransferQueue`, sampled ~8 times per second while transfers are active.
@MainActor
@Observable
final class TransfersModel {
    let queue: TransferQueue
    private(set) var snapshot = TransferQueueSnapshot.empty
    var onJobFinished: ((TransferJob) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var reportedFinished = Set<UUID>()

    init(storage: any ObjectStorage, partSize: Int64) {
        let executor = StorageTransferExecutor(storage: storage, limiter: AsyncLimiter(limit: 8), partSize: partSize, partConcurrency: 4)
        queue = TransferQueue(executor: executor, maxConcurrentJobs: 3, itemConcurrency: 4)
    }

    var jobs: [TransferJob] { snapshot.jobs }
    var activeCount: Int { snapshot.jobs.filter { !$0.status.isFinished && $0.status != .paused }.count }
    var hasJobs: Bool { !snapshot.jobs.isEmpty }

    /// Overall progress of unfinished jobs (nil when idle).
    var overallFraction: Double? {
        let active = snapshot.jobs.filter { $0.status == .running || $0.status == .queued }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(Int64(0)) { $0 &+ $1.totalBytes }
        let done = active.reduce(Int64(0)) { $0 &+ $1.transferredBytes }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    @discardableResult
    func enqueue(title: String, subtitle: String, direction: TransferDirection, items: [TransferItem]) async -> UUID {
        let id = await queue.enqueue(title: title, subtitle: subtitle, direction: direction, items: items)
        startPolling()
        return id
    }

    func pause(_ id: UUID) { Task { await queue.pause(id); await refresh() } }
    func resume(_ id: UUID) { Task { await queue.resume(id); startPolling() } }
    func cancel(_ id: UUID) { Task { await queue.cancel(id); await refresh() } }
    func retry(_ id: UUID) { Task { await queue.retry(id); startPolling() } }
    func remove(_ id: UUID) { Task { await queue.remove(id); await refresh() } }
    func clearFinished() { Task { await queue.clearFinished(); await refresh() } }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var idleTicks = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                if self.snapshot.jobs.contains(where: { $0.status == .running || $0.status == .queued }) {
                    idleTicks = 0
                } else {
                    idleTicks += 1
                    if idleTicks > 3 { break }
                }
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
            self?.pollTask = nil
        }
    }

    func refresh() async {
        let next = await queue.snapshot()
        snapshot = next
        for job in next.jobs where job.status.isFinished && !reportedFinished.contains(job.id) {
            reportedFinished.insert(job.id)
            onJobFinished?(job)
        }
    }

    func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        Task { await queue.cancelAll() }
    }
}
