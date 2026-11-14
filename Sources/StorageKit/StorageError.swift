import Foundation

/// Every failure surfaced by StorageKit. Never contains credentials.
public struct StorageError: Error, Sendable, Hashable, LocalizedError, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        /// The service answered with an error document or status.
        case service
        /// The request never produced an HTTP response (DNS, TLS, connection, timeout).
        case transport
        /// The operation was cancelled.
        case cancelled
        /// The response could not be understood (malformed XML, unexpected status, wrong length).
        case invalidResponse
        /// A response body exceeded the allowed size.
        case responseTooLarge
        /// The account is read-only and the operation would change data.
        case readOnly
        /// The request is invalid before it is sent (bad name, header, range, …).
        case invalidRequest
        /// A local file could not be read or written.
        case localFile
    }

    public var kind: Kind
    /// Provider error code, e.g. `NoSuchKey`, `AccessDenied`, `SlowDown`.
    public var code: String?
    public var message: String
    public var statusCode: Int?
    public var requestID: String?
    public var hostID: String?
    /// Extra fields from the error document (`Region`, `Endpoint`, `ServerTime`, `BucketName`, …).
    public var details: [String: String]
    /// Underlying `URLError` code for transport failures.
    public var urlErrorCode: Int?

    public init(kind: Kind, code: String? = nil, message: String, statusCode: Int? = nil, requestID: String? = nil,
                hostID: String? = nil, details: [String: String] = [:], urlErrorCode: Int? = nil) {
        self.kind = kind
        self.code = code
        self.message = message
        self.statusCode = statusCode
        self.requestID = requestID
        self.hostID = hostID
        self.details = details
        self.urlErrorCode = urlErrorCode
    }

    public static func invalidResponse(_ message: String) -> StorageError { StorageError(kind: .invalidResponse, message: message) }
    public static func invalidRequest(_ message: String) -> StorageError { StorageError(kind: .invalidRequest, message: message) }
    public static func localFile(_ message: String) -> StorageError { StorageError(kind: .localFile, message: message) }
    public static let cancelled = StorageError(kind: .cancelled, message: "The operation was cancelled.")
    public static let readOnly = StorageError(kind: .readOnly, code: "ReadOnlyAccount",
                                              message: "This account is read-only. Turn off read-only mode in the account settings to make changes.")

    public var errorDescription: String? { description }

    public var description: String {
        var text = message.isEmpty ? (code ?? "Request failed") : message
        var facts: [String] = []
        if let code, code != message { facts.append(code) }
        if let statusCode { facts.append("HTTP \(statusCode)") }
        if !facts.isEmpty { text += " (\(facts.joined(separator: ", ")))" }
        if let requestID { text += " · Request ID \(requestID)" }
        return text
    }

    public var isNotFound: Bool {
        statusCode == 404 || ["NoSuchKey", "NoSuchBucket", "NoSuchVersion", "NoSuchUpload", "NotFound"].contains(code ?? "")
    }

    public var isAccessDenied: Bool { statusCode == 403 || code == "AccessDenied" }

    public var isCancellation: Bool { kind == .cancelled }

    /// Codes that indicate throttling or a transient server-side problem.
    static let retryableCodes: Set<String> = [
        "SlowDown", "Throttling", "ThrottlingException", "ThrottledException", "RequestThrottled", "TooManyRequestsException",
        "RequestLimitExceeded", "BandwidthLimitExceeded", "RequestTimeout", "InternalError", "ServiceUnavailable",
        "OperationAborted", "Busy", "QpsLimitExceeded", "XMinioServerNotInitialized",
    ]

    /// Whether retrying the same request may succeed.
    public var isRetryable: Bool {
        switch kind {
        case .transport:
            return true
        case .service:
            if let code, Self.retryableCodes.contains(code) { return true }
            if let statusCode { return [500, 502, 503, 504, 429].contains(statusCode) }
            return false
        case .invalidResponse:
            // Truncated bodies or wrong lengths are typically transient network issues.
            return statusCode == nil || (statusCode.map { $0 >= 500 } ?? false)
        case .cancelled, .responseTooLarge, .readOnly, .invalidRequest, .localFile:
            return false
        }
    }

    // MARK: Mapping

    /// Parses an S3/OSS `<Error>` document (or synthesises an error from the status when the body is
    /// empty, as for HEAD requests).
    public static func fromResponse(statusCode: Int, headers: [String: String], body: Data, requestIDHeaders: [String]) -> StorageError {
        let requestID = requestIDHeaders.lazy.compactMap { headers[$0] }.first
        if !body.isEmpty, let root = try? XMLReader.parse(body, limits: XMLLimits(maxBytes: 1 << 20, maxDepth: 16, maxElements: 512, maxTextBytes: 1 << 18)),
           root.name == "Error" {
            var details: [String: String] = [:]
            for child in root.children where child.children.isEmpty && !["Code", "Message", "RequestId", "HostId"].contains(child.name) {
                details[child.name] = child.text
            }
            for (name, header) in [("Region", "x-amz-bucket-region")] where details[name] == nil {
                if let value = headers[header] { details[name] = value }
            }
            return StorageError(kind: .service, code: root.childText("Code"), message: root.childText("Message") ?? "",
                                statusCode: statusCode, requestID: root.childText("RequestId") ?? requestID,
                                hostID: root.childText("HostId"), details: details)
        }
        var details: [String: String] = [:]
        if let region = headers["x-amz-bucket-region"] { details["Region"] = region }
        let (code, message) = statusSummary(statusCode)
        return StorageError(kind: .service, code: code, message: message, statusCode: statusCode, requestID: requestID, details: details)
    }

    static func statusSummary(_ status: Int) -> (String?, String) {
        switch status {
        case 301: ("PermanentRedirect", "The bucket must be addressed using a different endpoint.")
        case 307: ("TemporaryRedirect", "The request was redirected to another endpoint.")
        case 400: ("BadRequest", "The request was rejected as invalid.")
        case 403: ("AccessDenied", "Access Denied")
        case 404: ("NotFound", "Not Found")
        case 405: ("MethodNotAllowed", "The operation is not allowed on this resource.")
        case 409: ("Conflict", "The request conflicts with the current state of the resource.")
        case 412: ("PreconditionFailed", "The object changed since the transfer started.")
        case 416: ("InvalidRange", "The requested range is not satisfiable.")
        case 429: ("TooManyRequests", "Too many requests; slow down.")
        case 500: ("InternalError", "The service reported an internal error.")
        case 501: ("NotImplemented", "The service does not implement this operation.")
        case 503: ("ServiceUnavailable", "The service is temporarily unavailable.")
        default: (nil, "The service answered with HTTP \(status).")
        }
    }

    /// Maps a thrown error from URLSession or elsewhere into a `StorageError`.
    public static func wrap(_ error: any Error) -> StorageError {
        if let error = error as? StorageError { return error }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            return StorageError(kind: .transport, message: urlError.localizedDescription, urlErrorCode: urlError.code.rawValue)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled { return .cancelled }
            return StorageError(kind: .transport, message: nsError.localizedDescription, urlErrorCode: nsError.code)
        }
        return StorageError(kind: .transport, message: error.localizedDescription)
    }
}
