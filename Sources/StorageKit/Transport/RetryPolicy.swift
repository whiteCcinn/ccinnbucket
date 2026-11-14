import Foundation
import os
import StorageSigning

/// Exponential backoff with "full jitter": delay = random(0, min(cap, base × 2^attempt)).
public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Returns a value in [0, 1). Injected for deterministic tests.
    public var random: @Sendable () -> Double
    /// Sleeps for the given number of seconds; must throw on cancellation.
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 0.25, maxDelay: TimeInterval = 20,
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 3600)) * 1_000_000_000))
                }) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.random = random
        self.sleep = sleep
    }

    public static let `default` = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Delay before retry number `attempt` (0-based: the delay after the first failure is `delay(0)`).
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt, 0), 30)
        let ceiling = min(maxDelay, baseDelay * pow(2, Double(exponent)))
        let fraction = min(max(random(), 0), 1)
        return ceiling * fraction
    }

    /// Whether a failure after `attempt` attempts (1-based count of attempts made) should be retried.
    public func shouldRetry(_ error: StorageError, attemptsMade: Int) -> Bool {
        attemptsMade < maxAttempts && error.isRetryable
    }
}

/// The signing clock: local time corrected by the offset learned from `RequestTimeTooSkewed` responses.
public final class SigningClock: Sendable {
    private let offset = OSAllocatedUnfairLock<TimeInterval>(initialState: 0)
    private let source: @Sendable () -> Date

    public init(source: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
    }

    public func now() -> Date { source().addingTimeInterval(offset.withLock { $0 }) }

    public var currentOffset: TimeInterval { offset.withLock { $0 } }

    /// Adopts the server's notion of "now". Returns whether the offset changed meaningfully.
    @discardableResult
    public func adjust(serverTime: Date) -> Bool {
        let newOffset = serverTime.timeIntervalSince(source())
        guard newOffset.isFinite, abs(newOffset) < 10 * 365 * 86_400 else { return false }
        return offset.withLock { current in
            defer { current = newOffset }
            return abs(current - newOffset) > 1
        }
    }
}

/// A counting semaphore for async code with FIFO fairness and cancellation-aware waiting.
/// Bounds concurrent parts/chunks across all transfers (and therefore their memory).
public actor AsyncLimiter {
    private var available: Int
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID: UInt64 = 0
    public let limit: Int

    public init(limit: Int) {
        self.limit = max(1, limit)
        self.available = max(1, limit)
    }

    public func acquire() async throws {
        try Task.checkCancellation()
        if available > 0, waiters.isEmpty {
            available -= 1
            return
        }
        let id = nextID
        nextID &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Runs `body` while holding one slot.
    public func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    public var inUse: Int { limit - available }
}
