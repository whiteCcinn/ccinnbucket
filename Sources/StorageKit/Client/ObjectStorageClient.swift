import Foundation
import os
import StorageSigning

/// The provider-neutral storage client: builds, signs, sends, retries and interprets requests.
/// Provider differences are delegated to a `ProviderDialect`.
public final class ObjectStorageClient: ObjectStorage {
    public let configuration: StorageConfiguration
    let credentials: SigningCredentials
    let transport: any HTTPTransport
    let retryPolicy: RetryPolicy
    public let clock: SigningClock
    let dialect: any ProviderDialect
    private let locations = OSAllocatedUnfairLock<[String: BucketLocation]>(initialState: [:])
    /// `.automatic` until the first listing decides between V2 and V1.
    private let listVersion: OSAllocatedUnfairLock<ListAPIVersion>

    public init(configuration: StorageConfiguration, credentials: SigningCredentials, transport: any HTTPTransport = URLSessionTransport(),
                retryPolicy: RetryPolicy = .default, clock: SigningClock = SigningClock()) {
        self.configuration = configuration
        self.credentials = credentials
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.clock = clock
        switch configuration.provider {
        case .s3: dialect = S3Dialect(configuration: configuration)
        case .oss: dialect = OSSDialect(configuration: configuration)
        }
        listVersion = OSAllocatedUnfairLock(initialState: configuration.listAPIVersion)
    }

    public var capabilities: StorageCapabilities {
        StorageCapabilities(provider: configuration.provider, storageClasses: dialect.storageClasses,
                            defaultStorageClass: dialect.defaultStorageClass, maxSingleCopySize: dialect.maxSingleCopySize,
                            maxPresignExpiry: AWSSigV4Signer.maximumExpiry)
    }

    public var isReadOnly: Bool { false }

    /// The list API currently in use (`.automatic` until a listing has run).
    public var effectiveListAPIVersion: ListAPIVersion { listVersion.withLock { $0 } }

    func setListVersion(_ version: ListAPIVersion) { listVersion.withLock { $0 = version } }

    // MARK: Bucket locations

    public func cachedLocation(of bucket: String) -> BucketLocation? { locations.withLock { $0[bucket] } }

    public func remember(_ location: BucketLocation, for bucket: String) { locations.withLock { $0[bucket] = location } }

    // MARK: Request execution

    struct Operation: Sendable {
        var method: String
        var bucket: String?
        var key: String?
        var query: [QueryParameter] = []
        var headers: [HTTPHeader] = []
        var body: Data?
        var sink: ResponseSink = .memory(limit: ResponseSink.defaultMemoryLimit)
        var progress: TransferProgressHandler?
        /// CopyObject, UploadPartCopy and CompleteMultipartUpload may report errors in a 200 response.
        var mayReturnErrorIn200 = false
        /// Add `Content-MD5` (required by DeleteObjects; used for integrity on OSS).
        var contentMD5 = false
        /// Statuses that count as success besides 2xx (e.g. 404 handled by the caller).
        var acceptedStatuses: Set<Int> = []
        /// Follow location hints (disabled for requests that are not bucket-scoped).
        var relocates = true
    }

    private enum AttemptOutcome {
        case success(HTTPResponse)
        case relocate(BucketLocation, StorageError)
        case correctedClock(StorageError)
        case failure(StorageError)
    }

    func execute(_ operation: Operation) async throws -> HTTPResponse {
        let payloadHash = operation.body.map { PayloadHash.sha256Hex($0) } ?? PayloadHash.empty
        var headers = operation.headers
        if let body = operation.body, !body.isEmpty, operation.contentMD5 || dialect.sendsContentMD5ForBodies,
           !headers.contains(where: { $0.name.lowercased() == "content-md5" }) {
            headers.append(HTTPHeader("Content-MD5", Hashing.md5Base64(body)))
        }
        try Self.validateHeaders(headers)
        var attempts = 0
        var relocated = false
        var clockCorrected = false
        while true {
            if Task.isCancelled { throw StorageError.cancelled }
            attempts += 1
            let outcome = await attempt(operation, headers: headers, payloadHash: payloadHash)
            let failure: StorageError
            switch outcome {
            case let .success(response):
                return response
            case let .relocate(location, error):
                // One free re-signed retry against the corrected region/endpoint.
                if !relocated, let bucket = operation.bucket {
                    relocated = true
                    attempts -= 1
                    remember(location, for: bucket)
                    continue
                }
                failure = error
            case let .correctedClock(error):
                // One free retry with the server-corrected clock.
                if !clockCorrected {
                    clockCorrected = true
                    attempts -= 1
                    continue
                }
                failure = error
            case let .failure(error):
                failure = error
            }
            guard retryPolicy.shouldRetry(failure, attemptsMade: attempts) else { throw failure }
            do {
                try await retryPolicy.sleep(retryPolicy.delay(forAttempt: attempts - 1))
            } catch {
                throw StorageError.cancelled
            }
        }
    }

    private func attempt(_ operation: Operation, headers: [HTTPHeader], payloadHash: String) async -> AttemptOutcome {
        let fallback = dialect.defaultLocation
        let location = operation.bucket.flatMap { cachedLocation(of: $0) } ?? fallback
        let target: ResolvedTarget
        do {
            target = try dialect.resolve(bucket: operation.bucket, key: operation.key,
                                         location: operation.bucket.flatMap { cachedLocation(of: $0) })
        } catch {
            return .failure(StorageError.wrap(error))
        }
        let signingRequest = SigningRequest(method: operation.method, host: target.hostHeader, path: target.path,
                                            query: operation.query, headers: headers, bucket: operation.bucket, key: operation.key)
        let authorization = dialect.sign(signingRequest, payloadHash: payloadHash, region: target.signingRegion,
                                         date: clock.now(), credentials: credentials)
        guard let url = target.url(encodedQuery: PercentEncoding.queryString(operation.query)) else {
            return .failure(.invalidRequest("Could not build a URL for this request."))
        }
        let request = HTTPRequest(method: operation.method, url: url, headers: headers + authorization, body: operation.body,
                                  timeout: configuration.requestTimeout)
        let reported = OSAllocatedUnfairLock<Int64>(initialState: 0)
        var progress: TransferProgressHandler?
        if let handler = operation.progress {
            progress = { @Sendable (delta: Int64) in
                reported.withLock { $0 += delta }
                handler(delta)
            }
        }
        func rollback() {
            let sent = reported.withLock { value -> Int64 in
                defer { value = 0 }
                return value
            }
            if sent != 0 { operation.progress?(-sent) }
        }

        let response: HTTPResponse
        do {
            response = try await transport.send(request, sink: operation.sink, progress: progress)
        } catch {
            rollback()
            return .failure(StorageError.wrap(error))
        }

        if let bucket = operation.bucket, let observed = dialect.observedLocation(response: response),
           observed.region != location.region, response.isSuccess {
            remember(observed, for: bucket)
        }
        if response.isSuccess || operation.acceptedStatuses.contains(response.statusCode) {
            if operation.mayReturnErrorIn200, response.statusCode == 200, let error = Self.errorDocument(in: response, dialect: dialect) {
                rollback()
                return .failure(error)
            }
            return .success(response)
        }
        rollback()
        let error = StorageError.fromResponse(statusCode: response.statusCode, headers: response.headers, body: response.body,
                                              requestIDHeaders: dialect.requestIDHeaders)
        if operation.relocates, operation.bucket != nil,
           let hint = dialect.relocationHint(error: error, response: response, attempted: location) {
            return .relocate(hint, error)
        }
        if error.code == "RequestTimeTooSkewed" {
            let serverTime = error.details["ServerTime"].flatMap(StorageDate.parseISO8601)
                ?? response.header("date").flatMap(SigningTime.parseHTTPDate)
            if let serverTime, clock.adjust(serverTime: serverTime) { return .correctedClock(error) }
        }
        return .failure(error)
    }

    /// CopyObject / CompleteMultipartUpload can answer 200 with an `<Error>` document.
    static func errorDocument(in response: HTTPResponse, dialect: any ProviderDialect) -> StorageError? {
        guard !response.body.isEmpty, let root = try? XMLReader.parse(response.body), root.name == "Error" else { return nil }
        var error = StorageError.fromResponse(statusCode: 200, headers: response.headers, body: response.body,
                                              requestIDHeaders: dialect.requestIDHeaders)
        if error.code == "InternalError" || error.code == "SlowDown" { error.statusCode = 500 }
        return error
    }

    /// Rejects header values that could smuggle extra headers (CR/LF) or are not representable.
    static func validateHeaders(_ headers: [HTTPHeader]) throws {
        for header in headers {
            let badName = header.name.isEmpty || header.name.unicodeScalars.contains { scalar in
                !(scalar.isASCII && scalar.value > 0x20 && scalar.value < 0x7F && !"()<>@,;:\\\"/[]?={}".unicodeScalars.contains(scalar))
            }
            let badValue = header.value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0.value == 0 }
            if badName || badValue {
                throw StorageError.invalidRequest("The header “\(header.name)” contains characters that cannot be sent.")
            }
        }
    }

    func xml(_ response: HTTPResponse) throws -> XElement { try XMLReader.parse(response.body) }

    // MARK: Presigning

    public func presignedURL(bucket: String, key: String, versionID: String?, method: String, expires: Int,
                             responseContentDisposition: String?) async throws -> URL {
        let target = try dialect.resolve(bucket: bucket, key: key, location: cachedLocation(of: bucket))
        var query: [QueryParameter] = []
        if let versionID { query.append(QueryParameter("versionId", versionID)) }
        if let disposition = responseContentDisposition { query.append(QueryParameter("response-content-disposition", disposition)) }
        let request = SigningRequest(method: method, host: target.hostHeader, path: target.path, query: query, bucket: bucket, key: key)
        let queryString: String
        do {
            queryString = try dialect.presign(request, region: target.signingRegion, expires: expires, date: clock.now(), credentials: credentials)
        } catch let error as SigningError {
            throw StorageError.invalidRequest(error.localizedDescription)
        }
        guard let url = URL(string: "\(target.scheme)://\(target.hostHeader)\(PercentEncoding.encodePath(target.path))?\(queryString)") else {
            throw StorageError.invalidRequest("Could not build the presigned URL.")
        }
        return url
    }
}
