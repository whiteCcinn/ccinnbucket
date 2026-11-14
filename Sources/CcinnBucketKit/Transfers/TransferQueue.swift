import Foundation
import os
import StorageKit

/// One unit of work inside a transfer job.
public struct TransferItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case upload(file: URL, bucket: String, key: String, options: ObjectWriteOptions)
        case download(bucket: String, key: String, versionID: String?, destination: URL)
        /// Server-side copy; `deleteSource` turns it into a move/rename.
        case copy(CopyObjectRequest, size: Int64?, deleteSource: Bool)
        /// Batch delete (≤ 1,000 objects).
        case delete(bucket: String, objects: [ObjectReference])
    }

    public let id: UUID
    public var kind: Kind
    /// Progress units: bytes for uploads/downloads/copies, objects for deletes.
    public var size: Int64

    public init(id: UUID = UUID(), kind: Kind, size: Int64) {
        self.id = id
        self.kind = kind
        self.size = max(0, size)
    }

    public var displayName: String {
        switch kind {
        case let .upload(_, _, key, _): ObjectPath.lastComponent(of: key)
        case let .download(_, key, _, _): ObjectPath.lastComponent(of: key)
        case let .copy(request, _, _): ObjectPath.lastComponent(of: request.sourceKey)
        case let .delete(_, objects): objects.count == 1 ? ObjectPath.lastComponent(of: objects[0].key) : "\(objects.count.formatted()) objects"
        }
    }
}

public enum TransferDirection: String, Sendable, Hashable, CaseIterable {
    case upload
    case download
    case copy
    case move
    case delete
}

public enum TransferStatus: Sendable, Hashable {
    case queued
    case running
    case paused
    case completed
    case failed(String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

public struct TransferFailure: Sendable, Hashable {
    public var name: String
    public var message: String
}

/// Snapshot of one job for the UI.
public struct TransferJob: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public var subtitle: String
    public var direction: TransferDirection
    public var status: TransferStatus
    public var totalBytes: Int64
    public var transferredBytes: Int64
    public var totalItems: Int
    public var completedItems: Int
    public var failures: [TransferFailure]
    public var bytesPerSecond: Double
    public var currentItem: String?
    public var createdAt: Date
    public var finishedAt: Date?

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return totalItems == 0 ? 1 : Double(completedItems) / Double(max(1, totalItems)) }
        return min(1, max(0, Double(transferredBytes) / Double(totalBytes)))
    }

    public var remainingTime: TimeInterval? {
        guard status == .running, bytesPerSecond > 1 else { return nil }
        return Double(max(0, totalBytes - transferredBytes)) / bytesPerSecond
    }

    public var canPause: Bool { status == .running || status == .queued }
    public var canResume: Bool { status == .paused }
    public var canRetry: Bool { if case .failed = status { true } else { false } }
    public var canCancel: Bool { !status.isFinished }
}

public struct TransferQueueSnapshot: Sendable, Hashable {
    public var jobs: [TransferJob]
    public var totalBytesPerSecond: Double
    public var activeCount: Int

    public static let empty = TransferQueueSnapshot(jobs: [], totalBytesPerSecond: 0, activeCount: 0)
}

/// Performs single items. Implemented over StorageKit engines in the app; faked in tests.
public protocol TransferExecutor: Sendable {
    /// Runs one item, reporting byte deltas (resumed items first report what is already done).
    /// Must throw `CancellationError`/`StorageError.cancelled` promptly when the task is cancelled.
    func execute(_ item: TransferItem, checkpoint: UploadCheckpoint?, progress: @escaping TransferProgressHandler,
                 onCheckpoint: @escaping @Sendable (UploadCheckpoint) -> Void) async throws
    /// Releases leftovers of an item that will not be resumed (abort a multipart upload, delete a partial file).
    func discard(_ item: TransferItem, checkpoint: UploadCheckpoint?) async
}

/// The transfer queue: bounded concurrent jobs, bounded concurrent items per job, pause/resume/cancel/retry.
/// Hot-path progress goes into per-job lock-protected counters (no actor hops per chunk); the UI samples
/// `snapshot()` a few times per second, which also updates the throughput meters.
public actor TransferQueue {
    /// Thread-safe progress and checkpoint storage written by executor callbacks.
    final class Box: Sendable {
        struct State: Sendable {
            private(set) var itemBytes: [UUID: Int64] = [:]
            /// Running sum of `itemBytes` (O(1) to read; updated with every delta).
            private(set) var total: Int64 = 0
            var checkpoints: [UUID: UploadCheckpoint] = [:]
            var current: String?

            mutating func set(_ id: UUID, _ bytes: Int64) {
                total &+= bytes &- (itemBytes[id] ?? 0)
                itemBytes[id] = bytes
            }

            mutating func add(_ id: UUID, _ delta: Int64) {
                itemBytes[id, default: 0] &+= delta
                total &+= delta
            }
        }

        let state = OSAllocatedUnfairLock(initialState: State())

        var total: Int64 { state.withLock { $0.total } }
    }

    private struct JobState {
        var job: TransferJob
        var items: [TransferItem]
        var done = Set<UUID>()
        var failed: [UUID: String] = [:]
        var task: Task<Void, Never>?
        var box = Box()
        var meter = ThroughputMeter()
        var stopReason: TransferStatus?
    }

    private let executor: any TransferExecutor
    public let maxConcurrentJobs: Int
    public let itemConcurrency: Int
    private let now: @Sendable () -> Date
    private var jobs: [UUID: JobState] = [:]
    private var order: [UUID] = []

    public init(executor: any TransferExecutor, maxConcurrentJobs: Int = 3, itemConcurrency: Int = 4,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.executor = executor
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
        self.itemConcurrency = max(1, itemConcurrency)
        self.now = now
    }

    // MARK: Commands

    @discardableResult
    public func enqueue(title: String, subtitle: String = "", direction: TransferDirection, items: [TransferItem]) -> UUID {
        let id = UUID()
        let job = TransferJob(id: id, title: title, subtitle: subtitle, direction: direction, status: .queued,
                              totalBytes: items.reduce(0) { $0 &+ $1.size }, transferredBytes: 0, totalItems: items.count, completedItems: 0,
                              failures: [], bytesPerSecond: 0, currentItem: nil, createdAt: now(), finishedAt: nil)
        jobs[id] = JobState(job: job, items: items)
        order.append(id)
        schedule()
        return id
    }

    public func pause(_ id: UUID) {
        guard var state = jobs[id] else { return }
        switch state.job.status {
        case .running:
            state.stopReason = .paused
            state.task?.cancel()
            jobs[id] = state
        case .queued:
            state.job.status = .paused
            jobs[id] = state
        default:
            break
        }
    }

    public func resume(_ id: UUID) {
        guard var state = jobs[id], state.job.status == .paused else { return }
        state.job.status = .queued
        state.stopReason = nil
        jobs[id] = state
        schedule()
    }

    public func cancel(_ id: UUID) {
        guard var state = jobs[id], !state.job.status.isFinished else { return }
        if state.job.status == .running {
            state.stopReason = .cancelled
            state.task?.cancel()
            jobs[id] = state
        } else {
            state.job.status = .cancelled
            state.job.finishedAt = now()
            jobs[id] = state
            discardUnfinished(of: state)
        }
    }

    /// Re-runs the failed items of a failed job.
    public func retry(_ id: UUID) {
        guard var state = jobs[id], case .failed = state.job.status else { return }
        state.failed = [:]
        state.job.failures = []
        state.job.status = .queued
        state.job.finishedAt = nil
        state.stopReason = nil
        jobs[id] = state
        schedule()
    }

    /// Removes a job that is not running (unfinished or failed items release their leftovers).
    public func remove(_ id: UUID) {
        guard let state = jobs[id], state.job.status != .running else { return }
        if state.job.status != .completed, state.job.status != .cancelled { discardUnfinished(of: state) }
        jobs[id] = nil
        order.removeAll { $0 == id }
    }

    /// Removes completed and cancelled jobs.
    public func clearFinished() {
        let finished = order.filter { id in
            guard let status = jobs[id]?.job.status else { return true }
            return status == .completed || status == .cancelled
        }
        for id in finished { jobs[id] = nil }
        order.removeAll { finished.contains($0) }
    }

    public func pauseAll() { for id in order { pause(id) } }

    public func cancelAll() { for id in order { cancel(id) } }

    // MARK: Observation

    public func job(_ id: UUID) -> TransferJob? {
        guard let state = jobs[id] else { return nil }
        return materialize(state)
    }

    /// Current state of every job; also advances the throughput meters.
    public func snapshot() -> TransferQueueSnapshot {
        let time = now()
        var result: [TransferJob] = []
        var total = 0.0
        for id in order {
            guard var state = jobs[id] else { continue }
            if state.job.status == .running {
                state.meter.record(totalBytes: state.box.total, at: time)
                total += state.meter.bytesPerSecond
            } else if state.meter.bytesPerSecond != 0 {
                state.meter.reset()
            }
            jobs[id] = state
            result.append(materialize(state))
        }
        return TransferQueueSnapshot(jobs: result, totalBytesPerSecond: total, activeCount: result.filter { $0.status == .running }.count)
    }

    private func materialize(_ state: JobState) -> TransferJob {
        var job = state.job
        job.transferredBytes = min(job.totalBytes, max(0, state.box.total))
        job.completedItems = state.done.count
        job.bytesPerSecond = job.status == .running ? state.meter.bytesPerSecond : 0
        job.currentItem = job.status == .running ? state.box.state.withLock { $0.current } : nil
        return job
    }

    // MARK: Scheduling

    private func schedule() {
        var running = jobs.values.filter { $0.job.status == .running }.count
        for id in order where running < maxConcurrentJobs {
            guard var state = jobs[id], state.job.status == .queued else { continue }
            state.job.status = .running
            state.stopReason = nil
            let pending = state.items.filter { !state.done.contains($0.id) }
            let box = state.box
            box.state.withLock { shared in for item in pending { shared.set(item.id, 0) } }
            let executor = executor
            let concurrency = itemConcurrency
            state.task = Task { [weak self] in
                let outcomes = await Self.run(pending, executor: executor, box: box, concurrency: concurrency)
                await self?.finish(id, outcomes: outcomes)
            }
            jobs[id] = state
            running += 1
        }
    }

    private enum ItemOutcome: Sendable {
        case done
        case failed(String)
        case stopped
    }

    private static func run(_ items: [TransferItem], executor: any TransferExecutor, box: Box, concurrency: Int) async -> [(UUID, ItemOutcome)] {
        await withTaskGroup(of: (UUID, ItemOutcome).self) { group in
            var iterator = items.makeIterator()
            func addNext() -> Bool {
                guard let item = iterator.next() else { return false }
                group.addTask {
                    let checkpoint = box.state.withLock { shared -> UploadCheckpoint? in
                        shared.set(item.id, 0)
                        shared.current = item.displayName
                        return shared.checkpoints[item.id]
                    }
                    do {
                        try Task.checkCancellation()
                        try await executor.execute(item, checkpoint: checkpoint, progress: { delta in
                            box.state.withLock { $0.add(item.id, delta) }
                        }, onCheckpoint: { checkpoint in
                            box.state.withLock { $0.checkpoints[item.id] = checkpoint }
                        })
                        box.state.withLock { shared in
                            shared.set(item.id, item.size)
                            shared.checkpoints[item.id] = nil
                        }
                        return (item.id, .done)
                    } catch {
                        let wrapped = StorageError.wrap(error)
                        if wrapped.isCancellation || Task.isCancelled { return (item.id, .stopped) }
                        return (item.id, .failed(wrapped.description))
                    }
                }
                return true
            }
            for _ in 0..<concurrency where addNext() {}
            var outcomes: [(UUID, ItemOutcome)] = []
            while let outcome = await group.next() {
                outcomes.append(outcome)
                if !Task.isCancelled { _ = addNext() }
            }
            return outcomes
        }
    }

    private func finish(_ id: UUID, outcomes: [(UUID, ItemOutcome)]) {
        guard var state = jobs[id] else { return }
        let names = Dictionary(state.items.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        for (itemID, outcome) in outcomes {
            switch outcome {
            case .done: state.done.insert(itemID)
            case let .failed(message): state.failed[itemID] = message
            case .stopped: break
            }
        }
        state.task = nil
        state.job.failures = state.failed.map { TransferFailure(name: names[$0.key] ?? "Item", message: $0.value) }
            .sorted { $0.name < $1.name }
        switch state.stopReason {
        case .paused?:
            state.job.status = .paused
        case .cancelled?:
            state.job.status = .cancelled
            state.job.finishedAt = now()
            discardUnfinished(of: state)
        default:
            if state.failed.isEmpty, state.done.count == state.items.count {
                state.job.status = .completed
            } else {
                let failedCount = max(state.failed.count, state.items.count - state.done.count)
                state.job.status = .failed("\(failedCount.formatted()) of \(state.items.count.formatted()) items failed")
            }
            state.job.finishedAt = now()
        }
        state.box.state.withLock { $0.current = nil }
        state.meter.reset()
        jobs[id] = state
        schedule()
    }

    private func discardUnfinished(of state: JobState) {
        let leftovers = state.items.filter { !state.done.contains($0.id) }
        let checkpoints = state.box.state.withLock { $0.checkpoints }
        let executor = executor
        Task.detached {
            for item in leftovers { await executor.discard(item, checkpoint: checkpoints[item.id]) }
        }
    }
}
