import Foundation
import os
import StorageSigning

/// `HTTPTransport` over one delegate-based `URLSession`.
///
/// * Redirects are never followed (a followed redirect would carry a signature for the wrong host);
///   the 3xx response is returned to the caller, which re-signs for the right endpoint.
/// * Bodies stream into memory (bounded) or straight into a file with `pwrite`, so downloads use constant memory.
/// * Upload and download progress are reported per chunk.
/// * Swift task cancellation cancels the URLSession task.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let router: TaskRouter

    public struct Configuration: Sendable {
        public var maximumConnectionsPerHost: Int
        /// Upper bound for one request including the body transfer.
        public var resourceTimeout: TimeInterval
        public var userAgent: String

        public init(maximumConnectionsPerHost: Int = 16, resourceTimeout: TimeInterval = 6 * 3600,
                    userAgent: String = "CcinnBucket/1.0 (macOS)") {
            self.maximumConnectionsPerHost = maximumConnectionsPerHost
            self.resourceTimeout = resourceTimeout
            self.userAgent = userAgent
        }
    }

    public init(configuration: Configuration = Configuration()) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpMaximumConnectionsPerHost = max(1, configuration.maximumConnectionsPerHost)
        sessionConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.httpAdditionalHeaders = ["User-Agent": configuration.userAgent]
        let router = TaskRouter()
        let queue = OperationQueue()
        queue.name = "CcinnBucket.URLSessionTransport"
        queue.maxConcurrentOperationCount = 1
        self.router = router
        self.session = URLSession(configuration: sessionConfiguration, delegate: router, delegateQueue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func send(_ request: HTTPRequest, sink: ResponseSink, progress: TransferProgressHandler?) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for header in request.headers { urlRequest.setValue(header.value, forHTTPHeaderField: header.name) }
        // Never let URLSession negotiate compression: bytes must match the object exactly.
        if urlRequest.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        let task: URLSessionTask
        if let body = request.body {
            task = session.uploadTask(with: urlRequest, from: body)
        } else {
            task = session.dataTask(with: urlRequest)
        }
        let identifier = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, any Error>) in
                router.register(identifier, state: TaskRouter.TaskState(continuation: continuation, sink: sink, progress: progress))
                if Task.isCancelled {
                    // The task never started: finish here (take-once), then make sure it can never run.
                    router.finish(identifier, throwing: .cancelled)
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// URLSession delegate that routes callbacks to per-task state. All mutable state lives behind one
/// unfair lock; callbacks arrive on the session's serial delegate queue, so contention is minimal.
final class TaskRouter: NSObject, URLSessionDataDelegate, Sendable {
    struct TaskState: Sendable {
        var continuation: CheckedContinuation<HTTPResponse, any Error>
        var sink: ResponseSink
        var progress: TransferProgressHandler?
        var statusCode = 0
        var headers: [String: String] = [:]
        var body = Data()
        var written: Int64 = 0
        var writingToFile = false
        var failure: StorageError?

        init(continuation: CheckedContinuation<HTTPResponse, any Error>, sink: ResponseSink, progress: TransferProgressHandler?) {
            self.continuation = continuation
            self.sink = sink
            self.progress = progress
        }
    }

    private let states = OSAllocatedUnfairLock<[Int: TaskState]>(initialState: [:])
    /// Error bodies are captured in memory up to this size even when the sink is a file.
    static let errorBodyLimit = 1 << 20

    func register(_ identifier: Int, state: TaskState) {
        states.withLock { $0[identifier] = state }
    }

    /// Resumes the task's continuation with an error if it is still pending (take-once).
    func finish(_ identifier: Int, throwing error: StorageError) {
        states.withLock { $0.removeValue(forKey: identifier) }?.continuation.resume(throwing: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        states.withLock { states in
            guard var state = states[dataTask.taskIdentifier] else { return }
            state.statusCode = http?.statusCode ?? 0
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                if let name = key as? String, let text = value as? String { headers[name.lowercased()] = text }
            }
            state.headers = headers
            if case let .file(_, _, _, accepted) = state.sink { state.writingToFile = accepted.contains(state.statusCode) }
            states[dataTask.taskIdentifier] = state
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        enum Action {
            case none
            case report(TransferProgressHandler)
            case cancel
            case write(descriptor: Int32, offset: Int64)
        }
        let identifier = dataTask.taskIdentifier
        let action: Action = states.withLock { states in
            guard var state = states[identifier], state.failure == nil else { return .none }
            defer { states[identifier] = state }
            switch state.sink {
            case let .memory(limit):
                guard state.body.count + data.count <= limit else {
                    state.failure = StorageError(kind: .responseTooLarge, message: "The response is larger than \(limit) bytes.",
                                                 statusCode: state.statusCode)
                    return .cancel
                }
                state.body.append(data)
                if (200..<300).contains(state.statusCode), let progress = state.progress { return .report(progress) }
                return .none
            case let .file(descriptor, offset, maxBytes, _):
                guard state.writingToFile else {
                    if state.body.count + data.count <= Self.errorBodyLimit { state.body.append(data) }
                    return .none
                }
                guard state.written + Int64(data.count) <= maxBytes else {
                    state.failure = StorageError(kind: .invalidResponse, message: "The server sent more data than requested.",
                                                 statusCode: state.statusCode)
                    return .cancel
                }
                let position = offset + state.written
                // Reserve the range now; callbacks for one task are serialised on the delegate queue.
                state.written += Int64(data.count)
                return .write(descriptor: descriptor, offset: position)
            }
        }
        switch action {
        case .none:
            break
        case let .report(progress):
            progress(Int64(data.count))
        case .cancel:
            dataTask.cancel()
        case let .write(descriptor, offset):
            // Disk I/O happens outside the lock.
            if let error = Self.write(data, to: descriptor, at: offset) {
                states.withLock { $0[identifier]?.failure = error }
                dataTask.cancel()
                return
            }
            if let progress = states.withLock({ $0[identifier]?.progress }) { progress(Int64(data.count)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        let progress = states.withLock { $0[task.taskIdentifier]?.progress }
        progress?(bytesSent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let state = states.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = state.failure {
            state.continuation.resume(throwing: failure)
        } else if let error {
            state.continuation.resume(throwing: StorageError.wrap(error))
        } else if state.statusCode == 0 {
            state.continuation.resume(throwing: StorageError.invalidResponse("The server did not send an HTTP response."))
        } else {
            state.continuation.resume(returning: HTTPResponse(statusCode: state.statusCode, headers: state.headers,
                                                              body: state.body, bytesWritten: state.written))
        }
    }

    /// Writes all of `data` at `offset`, retrying short writes and EINTR.
    static func write(_ data: Data, to descriptor: Int32, at offset: Int64) -> StorageError? {
        data.withUnsafeBytes { raw -> StorageError? in
            guard let base = raw.baseAddress else { return nil }
            var done = 0
            while done < raw.count {
                let result = pwrite(descriptor, base.advanced(by: done), raw.count - done, off_t(offset) + off_t(done))
                if result < 0 {
                    if errno == EINTR { continue }
                    return StorageError.localFile("Could not write the downloaded data: \(String(cString: strerror(errno))).")
                }
                if result == 0 { return StorageError.localFile("Could not write the downloaded data (disk full?).") }
                done += result
            }
            return nil
        }
    }
}
