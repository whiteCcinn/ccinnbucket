import Foundation
import os
import StorageSigning
@testable import StorageKit
import Testing

@Suite("Client: retries, regions, clock skew, errors")
struct ClientBehaviourTests {
    private static let emptyList = """
    <ListBucketResult><Name>b</Name><Prefix></Prefix><KeyCount>0</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated><EncodingType>url</EncodingType></ListBucketResult>
    """

    @Test("throttling is retried with backoff, then succeeds")
    func throttling() async throws {
        let sleeps = OSAllocatedUnfairLock<[TimeInterval]>(initialState: [])
        let transport = FakeTransport(responses: [Fixtures.error("SlowDown", status: 503), Fixtures.error("SlowDown", status: 503),
                                                  Fixtures.xml(Self.emptyList)])
        let retry = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 20, random: { 0.5 }, sleep: { seconds in sleeps.withLock { $0.append(seconds) } })
        let client = Fixtures.client(Fixtures.minio, transport: transport, retry: retry)
        let page = try await client.listObjects(ListObjectsRequest(bucket: "b"))
        #expect(page.objects.isEmpty)
        #expect(transport.requests.count == 3)
        #expect(sleeps.withLock { $0 } == [0.5, 1.0])
    }

    @Test("client errors are not retried; the error carries code, status and request id")
    func accessDenied() async {
        let transport = FakeTransport(responses: [Fixtures.error("AccessDenied", status: 403, message: "Access Denied")])
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        do {
            _ = try await client.listObjects(ListObjectsRequest(bucket: "b"))
            Issue.record("expected an error")
        } catch let error as StorageError {
            #expect(error.code == "AccessDenied")
            #expect(error.statusCode == 403)
            #expect(error.requestID == "REQ123")
            #expect(error.description == "Access Denied (AccessDenied, HTTP 403) · Request ID REQ123")
            #expect(!error.description.contains(Fixtures.credentials.secretAccessKey))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(transport.requests.count == 1)
    }

    @Test("attempts are bounded")
    func boundedAttempts() async {
        let transport = FakeTransport(responses: [Fixtures.error("InternalError", status: 500)])
        let client = Fixtures.client(Fixtures.minio, transport: transport, retry: RetryPolicy(maxAttempts: 3, random: { 0 }, sleep: { _ in }))
        await #expect(throws: StorageError.self) { try await client.headBucket("b") }
        #expect(transport.requests.count == 3)
    }

    @Test("transport failures are retried")
    func transportRetry() async throws {
        let transport = FakeTransport { _, index in
            if index == 0 { throw URLError(.networkConnectionLost) }
            return HTTPResponse(statusCode: 200)
        }
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        try await client.headBucket("b")
        #expect(transport.requests.count == 2)
    }

    @Test("full-jitter delays stay within the exponential ceiling")
    func jitter() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: 0.25, maxDelay: 20, random: { 0.999 })
        #expect(policy.delay(forAttempt: 0) < 0.25)
        #expect(policy.delay(forAttempt: 3) < 2.0)
        #expect(policy.delay(forAttempt: 30) <= 20)
        #expect(policy.delay(forAttempt: Int.max) <= 20)
        #expect(RetryPolicy(random: { 0 }).delay(forAttempt: 5) == 0)
    }

    @Test("301 with x-amz-bucket-region re-signs for the bucket's region and remembers it")
    func permanentRedirect() async throws {
        let transport = FakeTransport { request, _ in
            if request.url.host == "photos.s3.us-east-1.amazonaws.com" {
                return Fixtures.error("PermanentRedirect", status: 301, extra: "<Endpoint>photos.s3.eu-west-1.amazonaws.com</Endpoint>",
                                      headers: ["x-amz-bucket-region": "eu-west-1"])
            }
            return Fixtures.xml(Self.emptyList)
        }
        let client = Fixtures.client(Fixtures.aws, transport: transport)
        _ = try await client.listObjects(ListObjectsRequest(bucket: "photos"))
        _ = try await client.listObjects(ListObjectsRequest(bucket: "photos"))
        let hosts = transport.requests.map { $0.url.host ?? "" }
        #expect(hosts == ["photos.s3.us-east-1.amazonaws.com", "photos.s3.eu-west-1.amazonaws.com", "photos.s3.eu-west-1.amazonaws.com"])
        #expect(transport.requests[1].header("Authorization")?.contains("/eu-west-1/s3/aws4_request") == true)
        #expect(client.cachedLocation(of: "photos")?.region == "eu-west-1")
    }

    @Test("AuthorizationHeaderMalformed with <Region> on a custom endpoint re-signs for that region")
    func malformedAuthorizationRegion() async throws {
        let transport = FakeTransport { request, _ in
            if request.header("Authorization")?.contains("/us-east-1/") == true {
                return Fixtures.error("AuthorizationHeaderMalformed", status: 400, extra: "<Region>eu-central-1</Region>")
            }
            return HTTPResponse(statusCode: 200)
        }
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        try await client.headBucket("b")
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].url.host == "127.0.0.1")
        #expect(transport.requests[1].header("Authorization")?.contains("/eu-central-1/s3/") == true)
    }

    @Test("OSS AccessDenied with <Endpoint> moves the bucket to its region endpoint")
    func ossEndpointHint() async throws {
        let transport = FakeTransport { request, _ in
            if request.url.host == "bkt.oss-cn-hangzhou.aliyuncs.com" {
                return Fixtures.error("AccessDenied", status: 403, message: "The bucket you are attempting to access must be addressed using the specified endpoint.",
                                      extra: "<Endpoint>oss-cn-shanghai.aliyuncs.com</Endpoint>")
            }
            return HTTPResponse(statusCode: 200)
        }
        let client = Fixtures.client(Fixtures.oss, transport: transport)
        try await client.headBucket("bkt")
        #expect(transport.requests.map { $0.url.host ?? "" } == ["bkt.oss-cn-hangzhou.aliyuncs.com", "bkt.oss-cn-shanghai.aliyuncs.com"])
        #expect(transport.requests[1].header("Authorization")?.contains("/cn-shanghai/oss/aliyun_v4_request") == true)
    }

    @Test("a second redirect is not followed forever")
    func redirectLoop() async {
        let transport = FakeTransport { request, _ in
            let next = request.header("Authorization")?.contains("/eu-west-1/") == true ? "us-east-1" : "eu-west-1"
            return Fixtures.error("PermanentRedirect", status: 301, headers: ["x-amz-bucket-region": next])
        }
        let client = Fixtures.client(Fixtures.aws, transport: transport)
        await #expect(throws: StorageError.self) { try await client.headBucket("ping-pong") }
        #expect(transport.requests.count == 2)
    }

    @Test("RequestTimeTooSkewed corrects the signing clock from ServerTime and retries once")
    func clockSkew() async throws {
        let transport = FakeTransport { request, index in
            if index == 0 {
                return Fixtures.error("RequestTimeTooSkewed", status: 403, extra: "<RequestTime>20261114T083015Z</RequestTime><ServerTime>2026-11-14T08:50:15Z</ServerTime>")
            }
            return HTTPResponse(statusCode: 200)
        }
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        try await client.headBucket("b")
        #expect(transport.requests[0].header("x-amz-date") == "20261114T083015Z")
        #expect(transport.requests[1].header("x-amz-date") == "20261114T085015Z")
        #expect(abs(client.clock.currentOffset - 1200) < 0.001)
    }

    @Test("an error document inside a 200 CompleteMultipartUpload is surfaced (and retried when transient)")
    func errorIn200() async throws {
        let transport = FakeTransport(responses: [
            Fixtures.xml("<Error><Code>InternalError</Code><Message>We encountered an internal error.</Message></Error>"),
            Fixtures.xml("<CompleteMultipartUploadResult><ETag>\"abc-2\"</ETag></CompleteMultipartUploadResult>"),
        ])
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        let result = try await client.completeMultipartUpload(bucket: "b", key: "k", uploadID: "u",
                                                              parts: [UploadedPart(partNumber: 2, eTag: "\"e2\"", size: 5), UploadedPart(partNumber: 1, eTag: "\"e1\"", size: 5)])
        #expect(result.eTag == "\"abc-2\"")
        #expect(transport.requests.count == 2)
        let body = String(decoding: transport.requests[0].body ?? Data(), as: UTF8.self)
        #expect(body.contains("<Part><PartNumber>1</PartNumber><ETag>&quot;e1&quot;</ETag></Part><Part><PartNumber>2</PartNumber>"))
    }

    @Test("CR/LF in metadata is rejected before anything is sent")
    func headerInjection() async {
        let transport = FakeTransport(responses: [HTTPResponse(statusCode: 200)])
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        await #expect(throws: StorageError.self) {
            _ = try await client.putObject(bucket: "b", key: "k", body: Data("x".utf8),
                                           options: ObjectWriteOptions(userMetadata: ["note": "a\r\nx-amz-acl: public-read"]), progress: nil)
        }
        await #expect(throws: StorageError.self) {
            _ = try await client.putObject(bucket: "b", key: "k", body: Data(), options: ObjectWriteOptions(contentType: "text/plain\nX: y"), progress: nil)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("cancellation during a backoff stops promptly")
    func cancellationDuringBackoff() async {
        let transport = FakeTransport(responses: [Fixtures.error("SlowDown", status: 503)])
        let retry = RetryPolicy(maxAttempts: 10, baseDelay: 30, maxDelay: 30, random: { 1 },
                                sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) })
        let client = Fixtures.client(Fixtures.minio, transport: transport, retry: retry)
        let task = Task { try await client.headBucket("b") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let started = Date()
        let result = await task.result
        #expect(Date().timeIntervalSince(started) < 2)
        if case let .failure(error as StorageError) = result {
            #expect(error.isCancellation)
        } else {
            Issue.record("expected cancellation, got \(result)")
        }
    }

    @Test("progress of a failed attempt is rolled back")
    func progressRollback() async throws {
        let total = OSAllocatedUnfairLock<Int64>(initialState: 0)
        let transport = FakeTransport { _, index in
            if index == 0 { return Fixtures.error("InternalError", status: 500) }
            return HTTPResponse(statusCode: 200, headers: ["ETag": "\"e\""])
        }
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        _ = try await client.uploadPart(bucket: "b", key: "k", uploadID: "u", partNumber: 1, body: Data(count: 1000),
                                        progress: { delta in total.withLock { $0 += delta } })
        #expect(total.withLock { $0 } == 1000)
    }

    @Test("read-only storage refuses mutations without sending requests")
    func readOnly() async {
        let transport = FakeTransport(responses: [HTTPResponse(statusCode: 200)])
        let storage = ReadOnlyStorage(Fixtures.client(Fixtures.minio, transport: transport))
        await #expect(throws: StorageError.readOnly) { try await storage.deleteObject(bucket: "b", key: "k", versionID: nil) }
        await #expect(throws: StorageError.readOnly) { _ = try await storage.deleteObjects(bucket: "b", objects: [ObjectReference(key: "k")]) }
        await #expect(throws: StorageError.readOnly) { _ = try await storage.putObject(bucket: "b", key: "k", body: Data(), options: .init(), progress: nil) }
        await #expect(throws: StorageError.readOnly) { try await storage.createBucket("new-bucket", region: nil) }
        await #expect(throws: StorageError.readOnly) { try await storage.setVersioning(bucket: "b", enabled: true) }
        await #expect(throws: StorageError.readOnly) { try await storage.abortMultipartUpload(bucket: "b", key: "k", uploadID: "u") }
        await #expect(throws: StorageError.readOnly) {
            _ = try await storage.copyObject(CopyObjectRequest(sourceBucket: "b", sourceKey: "a", destinationBucket: "b", destinationKey: "c"))
        }
        await #expect(throws: StorageError.readOnly) {
            _ = try await storage.presignedURL(bucket: "b", key: "k", versionID: nil, method: "PUT", expires: 60, responseContentDisposition: nil)
        }
        #expect(transport.requests.isEmpty)
        #expect(storage.isReadOnly)
    }

    @Test("error mapping without a body (HEAD) uses the status")
    func headErrors() {
        let error = StorageError.fromResponse(statusCode: 404, headers: ["x-amz-request-id": "R1"], body: Data(), requestIDHeaders: ["x-amz-request-id"])
        #expect(error.isNotFound)
        #expect(error.requestID == "R1")
        #expect(StorageError.wrap(URLError(.cancelled)).isCancellation)
        #expect(StorageError.wrap(URLError(.timedOut)).isRetryable)
        #expect(StorageError.wrap(CancellationError()).isCancellation)
    }
}
