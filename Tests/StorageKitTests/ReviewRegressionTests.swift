import Foundation
import Network
import os
import StorageSigning
@testable import StorageKit
import Testing

/// Regression tests for the adversarial review findings (StorageKit).
@Suite("Review regressions: StorageKit")
struct ReviewRegressionTests {
    private static let mib: Int64 = 1 << 20

    @Test("two downloads to the same destination never corrupt each other; leftovers of a running download are kept")
    func sameDestination() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = OSAllocatedUnfairLock(initialState: false)
        let storage = InMemoryStorage(rangeHook: { _ in
            while !release.withLock({ $0 }) { try await Task.sleep(nanoseconds: 5_000_000) }
        })
        let first = TempFiles.randomData(Int(2 * Self.mib), seed: 1)
        storage.store("b", "2024/report.pdf", first)
        storage.store("b", "2023/report.pdf", TempFiles.randomData(Int(3 * Self.mib), seed: 2))
        let destination = directory.appendingPathComponent("report.pdf")
        let downloader = ObjectDownloader(storage: storage, limiter: AsyncLimiter(limit: 4), chunkSize: Self.mib)
        let running = Task { try await downloader.download(bucket: "b", key: "2024/report.pdf", versionID: nil, to: destination, progress: { _ in }) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: ObjectDownloader.partialURL(for: destination).path) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await #expect(throws: StorageError.self) {
            try await downloader.download(bucket: "b", key: "2023/report.pdf", versionID: nil, to: destination, progress: { _ in })
        }
        ObjectDownloader.discardPartial(for: destination)
        #expect(FileManager.default.fileExists(atPath: ObjectDownloader.partialURL(for: destination).path), "a running download keeps its partial file")
        release.withLock { $0 = true }
        _ = try await running.value
        #expect(try Data(contentsOf: destination) == first)
    }

    @Test("implausible sizes reported by a server are rejected before allocating anything")
    func implausibleSize() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = InMemoryStorage()
        storage.store("b", "k", Data("x".utf8))
        storage.state.withLock { $0.sizeOverride = Int64.max - 10 }
        await #expect(throws: StorageError.self) {
            try await ObjectDownloader(storage: storage, limiter: AsyncLimiter(limit: 1))
                .download(bucket: "b", key: "k", versionID: nil, to: directory.appendingPathComponent("k"), progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: ObjectDownloader.partialURL(for: directory.appendingPathComponent("k")).path))
    }

    @Test("resuming an upload whose multipart upload was aborted starts a new one instead of failing forever")
    func resumeAfterAbort() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("f.bin")
        let content = TempFiles.randomData(Int(11 * Self.mib), seed: 5)
        try content.write(to: file)
        let storage = InMemoryStorage()
        let uploader = ObjectUploader(storage: storage, limiter: AsyncLimiter(limit: 8))
        let reader = try LocalFileReader(url: file)
        let staleID = try await storage.createMultipartUpload(bucket: "b", key: "f.bin", options: ObjectWriteOptions())
        try await storage.abortMultipartUpload(bucket: "b", key: "f.bin", uploadID: staleID)
        let stale = UploadCheckpoint(bucket: "b", key: "f.bin", uploadID: staleID, partSize: 5 * Self.mib, fileSize: reader.size,
                                     fileModification: reader.modificationDate, parts: [UploadedPart(partNumber: 1, eTag: "\"x\"", size: 5 * Self.mib)])
        _ = try await uploader.upload(file: file, bucket: "b", key: "f.bin", options: ObjectWriteOptions(), partSize: 5 * Self.mib,
                                      checkpoint: stale, progress: { _ in }, onCheckpoint: { _ in })
        #expect(storage.object("b", "f.bin")?.data == content)
    }

    @Test("a lost CompleteMultipartUpload response is recognised when the object exists with the right size")
    func lostCompleteResponse() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("g.bin")
        try TempFiles.randomData(Int(11 * Self.mib), seed: 6).write(to: file)
        let storage = InMemoryStorage()
        storage.state.withLock { $0.completeLosesResponse = true }
        let result = try await ObjectUploader(storage: storage, limiter: AsyncLimiter(limit: 8)).upload(
            file: file, bucket: "b", key: "g.bin", options: ObjectWriteOptions(), partSize: 5 * Self.mib, progress: { _ in }, onCheckpoint: { _ in })
        #expect(result.eTag?.hasSuffix("-3\"") == true)
    }

    @Test("upload memory is bounded by bytes, not by part count")
    func weightedMemory() async throws {
        let directory = try TempFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("h.bin")
        try TempFiles.randomData(Int(40 * Self.mib), seed: 7).write(to: file)
        let storage = InMemoryStorage(partHook: { _ in try await Task.sleep(nanoseconds: 10_000_000) })
        // 4 units of 8 MiB = 32 MiB budget; 16 MiB parts take 2 units each → at most 2 parts in memory.
        _ = try await ObjectUploader(storage: storage, limiter: AsyncLimiter(limit: 4), partConcurrency: 8).upload(
            file: file, bucket: "b", key: "h.bin", options: ObjectWriteOptions(), partSize: 16 * Self.mib, progress: { _ in }, onCheckpoint: { _ in })
        #expect(storage.state.withLock { $0.maxActiveParts } <= 2)
        let limiter = AsyncLimiter(limit: 4)
        try await limiter.acquire(units: 3)
        let big = Task { try await limiter.acquire(units: 4) }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(await limiter.inUse == 3)
        await limiter.release(units: 3)
        try await big.value
        #expect(await limiter.inUse == 4)
        await limiter.release(units: 4)
        try await limiter.acquire(units: 99)
        #expect(await limiter.inUse == 4, "requests larger than the limit are clamped")
    }

    @Test("multipart copies keep the source tags")
    func copyKeepsTags() async throws {
        let storage = InMemoryStorage(maxSingleCopySize: 6 * Self.mib)
        storage.store("b", "big", TempFiles.randomData(Int(13 * Self.mib)))
        try await storage.putObjectTags(bucket: "b", key: "big", versionID: nil, tags: [ObjectTag(key: "env", value: "prod")])
        _ = try await ServerSideCopier(storage: storage, partSize: 5 * Self.mib).copy(
            CopyObjectRequest(sourceBucket: "b", sourceKey: "big", destinationBucket: "b", destinationKey: "moved"))
        #expect(try await storage.getObjectTags(bucket: "b", key: "moved", versionID: nil) == [ObjectTag(key: "env", value: "prod")])
    }

    @Test("header values are trimmed before signing, matching what the server receives")
    func trimmedHeaders() async throws {
        let transport = FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: ["ETag": "\"e\""])])
        _ = try await Fixtures.client(Fixtures.oss, transport: transport).putObject(
            bucket: "bkt", key: "k", body: Data("x".utf8), options: ObjectWriteOptions(userMetadata: ["note": "hello  "]), progress: nil)
        #expect(transport.requests.first?.header("x-oss-meta-note") == "hello")
    }

    @Test("a clock already corrected by a parallel request triggers a retry instead of a failure")
    func parallelSkewCorrection() async throws {
        let clock = SigningClock(source: { Date(timeIntervalSince1970: 1_794_645_015) })
        let transport = FakeTransport { _, index in
            if index == 0 {
                clock.adjust(serverTime: Date(timeIntervalSince1970: 1_794_645_015 + 1_200)) // another request got there first
                return Fixtures.error("RequestTimeTooSkewed", status: 403, extra: "<ServerTime>2026-11-14T08:50:15Z</ServerTime>")
            }
            return HTTPResponse(statusCode: 200)
        }
        let client = Fixtures.client(Fixtures.minio, transport: transport, clock: clock)
        try await client.headBucket("b")
        #expect(transport.requests.count == 2)
        #expect(transport.requests[1].header("x-amz-date") == "20261114T085015Z")
    }

    @Test("only plain regional AWS endpoints are rewritten per region", arguments: [
        ("s3.amazonaws.com", true), ("s3.eu-west-1.amazonaws.com", true), ("s3-us-west-2.amazonaws.com", true),
        ("s3.cn-north-1.amazonaws.com.cn", true), ("s3-fips.us-east-1.amazonaws.com", false), ("s3.dualstack.eu-west-1.amazonaws.com", false),
        ("s3-accelerate.amazonaws.com", false), ("bucket.vpce-0a1b2c3d-abcdefgh.s3.us-east-1.vpce.amazonaws.com", false),
        ("minio.example.com", false),
    ])
    func awsHosts(_ host: String, _ regional: Bool) {
        #expect(S3Dialect.isPlainRegionalAWSHost(host) == regional)
    }

    @Test("special AWS endpoints such as FIPS are used exactly as configured")
    func fipsEndpoint() throws {
        let configuration = StorageConfiguration(provider: .s3, endpoint: StorageEndpoint(scheme: "https", host: "s3-fips.us-east-1.amazonaws.com"),
                                                 region: "us-east-1")
        let target = try S3Dialect(configuration: configuration).resolve(bucket: "data", key: "k", location: BucketLocation(region: "eu-west-1"))
        #expect(target.host == "data.s3-fips.us-east-1.amazonaws.com")
        #expect(target.signingRegion == "eu-west-1")
    }

    @Test("a short 206 is not accepted as a complete chunk")
    func shortRange() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-short-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 20))
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_RDWR)
        defer { close(descriptor) }
        let transport = FakeTransport(responses: [HTTPResponse(statusCode: 206, headers: ["Content-Range": "bytes 10-12/20"], body: Data("ABC".utf8))])
        await #expect(throws: StorageError.self) {
            _ = try await Fixtures.client(Fixtures.minio, transport: transport, retry: .none).downloadObject(
                bucket: "b", key: "k", versionID: nil, range: ByteRange(first: 10, last: 19), ifMatch: nil, descriptor: descriptor, fileOffset: 10,
                progress: nil)
        }
    }

    @Test("a server that ignores Range is not downloaded to the end")
    func ignoredRangeStopsEarly() async throws {
        let server = try BigBodyServer(bytes: 400 << 20)
        defer { server.stop() }
        let port = try await server.start()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-big-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_RDWR)
        defer { close(descriptor) }
        var configuration = Fixtures.minio
        configuration.endpoint = StorageEndpoint(scheme: "http", host: "127.0.0.1", port: port)
        let client = ObjectStorageClient(configuration: configuration, credentials: Fixtures.credentials, transport: URLSessionTransport(),
                                         retryPolicy: .none)
        let started = Date()
        await #expect(throws: StorageError.self) {
            _ = try await client.downloadObject(bucket: "b", key: "k", versionID: nil, range: ByteRange(first: 100, last: 199), ifMatch: nil,
                                                descriptor: descriptor, fileOffset: 0, progress: nil)
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(server.bytesSent < 200 << 20, "the transfer was stopped long before the 400 MB body ended")
        var info = stat()
        fstat(descriptor, &info)
        #expect(info.st_size == 0, "nothing was written to the file")
    }
}

/// Minimal HTTP server that answers every request with `200 OK` and a large body.
final class BigBodyServer: Sendable {
    private let listener: NWListener
    private let total: Int
    private let sent = OSAllocatedUnfairLock(initialState: 0)
    private let queue = DispatchQueue(label: "BigBodyServer")

    init(bytes: Int) throws {
        listener = try NWListener(using: .tcp, on: .any)
        total = bytes
    }

    var bytesSent: Int { sent.withLock { $0 } }

    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 { return Int(port) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw StorageError.invalidResponse("listener did not start")
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, _, _ in
            guard let self else { return }
            let header = "HTTP/1.1 200 OK\r\nContent-Length: \(self.total)\r\nContent-Type: application/octet-stream\r\n\r\n"
            connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in self.sendChunk(connection, remaining: self.total) })
        }
    }

    private func sendChunk(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { return }
        let size = min(remaining, 1 << 20)
        connection.send(content: Data(count: size), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.sent.withLock { $0 += size }
            self.sendChunk(connection, remaining: remaining - size)
        })
    }
}
