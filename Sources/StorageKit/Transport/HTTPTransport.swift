import Foundation
import StorageSigning

/// A fully built, signed HTTP request.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [HTTPHeader]
    public var body: Data?
    /// Idle timeout: the longest time without any bytes moving.
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [HTTPHeader] = [], body: Data? = nil, timeout: TimeInterval = 60) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.last { $0.name.lowercased() == lowered }?.value
    }
}

/// Response status, headers (lower-cased names) and, for memory sinks, the body.
public struct HTTPResponse: Sendable, Hashable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
    /// Bytes written to the file sink (0 for memory sinks).
    public var bytesWritten: Int64

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data(), bytesWritten: Int64 = 0) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
        self.bytesWritten = bytesWritten
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Where a response body goes.
public enum ResponseSink: Sendable, Hashable {
    /// Collect in memory; a body larger than `limit` fails with `.responseTooLarge`.
    case memory(limit: Int)
    /// Stream into an open file at `offset` (via `pwrite`), but only when the status is in `acceptedStatuses`;
    /// other responses are captured in memory (bounded) as error documents. More than `maxBytes` fails.
    case file(descriptor: Int32, offset: Int64, maxBytes: Int64, acceptedStatuses: Set<Int>)

    public static let defaultMemoryLimit = 16 << 20
}

/// Reports transferred bytes as deltas. Negative values roll back a failed attempt.
public typealias TransferProgressHandler = @Sendable (Int64) -> Void

/// Executes HTTP requests. `URLSessionTransport` in production, scripted fakes in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest, sink: ResponseSink, progress: TransferProgressHandler?) async throws -> HTTPResponse
}

extension HTTPTransport {
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await send(request, sink: .memory(limit: ResponseSink.defaultMemoryLimit), progress: nil)
    }
}
