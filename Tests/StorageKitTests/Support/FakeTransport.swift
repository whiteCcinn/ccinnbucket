import Foundation
import os
import StorageSigning
@testable import StorageKit

/// Scripted `HTTPTransport`: records every request and answers from a handler (or a queue of responses).
final class FakeTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest, Int) throws -> HTTPResponse

    private let handler: Handler
    private let recorded = OSAllocatedUnfairLock<[HTTPRequest]>(initialState: [])

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers with `responses` in order (the last one repeats).
    convenience init(responses: [HTTPResponse]) {
        self.init { _, index in
            guard let last = responses.last else { return HTTPResponse(statusCode: 200) }
            return index < responses.count ? responses[index] : last
        }
    }

    var requests: [HTTPRequest] { recorded.withLock { $0 } }

    func send(_ request: HTTPRequest, sink: ResponseSink, progress: TransferProgressHandler?) async throws -> HTTPResponse {
        let index = recorded.withLock { list -> Int in
            list.append(request)
            return list.count - 1
        }
        if Task.isCancelled { throw StorageError.cancelled }
        var response = try handler(request, index)
        if let body = request.body { progress?(Int64(body.count)) }
        switch sink {
        case let .memory(limit):
            if response.body.count > limit {
                throw StorageError(kind: .responseTooLarge, message: "too large", statusCode: response.statusCode)
            }
            if response.isSuccess, request.body == nil { progress?(Int64(response.body.count)) }
        case let .file(descriptor, offset, maxBytes, accepted):
            if accepted.contains(response.statusCode) {
                if Int64(response.body.count) > maxBytes { throw StorageError.invalidResponse("more data than requested") }
                if let error = TaskRouter.write(response.body, to: descriptor, at: offset) { throw error }
                response.bytesWritten = Int64(response.body.count)
                progress?(Int64(response.body.count))
                response.body = Data()
            }
        }
        return response
    }
}

enum Fixtures {
    static let credentials = SigningCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret/key+example")

    static func client(_ configuration: StorageConfiguration, transport: FakeTransport,
                       retry: RetryPolicy = RetryPolicy(maxAttempts: 4, random: { 0.5 }, sleep: { _ in }),
                       clock: SigningClock = SigningClock(source: { Date(timeIntervalSince1970: 1_794_645_015) })) -> ObjectStorageClient {
        ObjectStorageClient(configuration: configuration, credentials: credentials, transport: transport, retryPolicy: retry, clock: clock)
    }

    static let minio = StorageConfiguration(provider: .s3, endpoint: StorageEndpoint(scheme: "http", host: "127.0.0.1", port: 19900),
                                            region: "us-east-1", addressing: .path)
    static let aws = StorageConfiguration(provider: .s3, region: "us-east-1")
    static let oss = StorageConfiguration(provider: .oss, region: "cn-hangzhou")

    static func xml(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: headers, body: Data(text.utf8))
    }

    static func error(_ code: String, status: Int, message: String = "msg", extra: String = "", headers: [String: String] = [:]) -> HTTPResponse {
        xml("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(message)</Message>\(extra)<RequestId>REQ123</RequestId></Error>",
            status: status, headers: headers)
    }

    static func query(_ request: HTTPRequest) -> [String: String] {
        var result: [String: String] = [:]
        for item in URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}
