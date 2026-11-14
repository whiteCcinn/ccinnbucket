import CryptoKit
import Foundation
import os
import StorageKit
import StorageSigning
import Testing

/// Live tests against the MinIO container started by `scripts/storage-up.sh`.
///
///     eval "$(scripts/storage-up.sh)"
///     swift test --filter IntegrationTests
///
/// Skipped unless `CCINNBUCKET_IT` is set. Never point these at a real cloud account.
enum IT {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["CCINNBUCKET_IT"] != nil
    static let bulkCount = Int(environment["CCINNBUCKET_IT_BULK_COUNT"] ?? "") ?? 50_000

    static var endpoint: StorageEndpoint {
        StorageEndpoint(string: environment["CCINNBUCKET_IT_ENDPOINT"] ?? "http://127.0.0.1:19900")
            ?? StorageEndpoint(scheme: "http", host: "127.0.0.1", port: 19900)
    }

    static var credentials: SigningCredentials {
        SigningCredentials(accessKeyID: environment["CCINNBUCKET_IT_ACCESS_KEY"] ?? "ccinnbucket",
                           secretAccessKey: environment["CCINNBUCKET_IT_SECRET_KEY"] ?? "ccinnbucket-local-secret")
    }

    static func configuration(region: String? = nil, listVersion: ListAPIVersion = .automatic) -> StorageConfiguration {
        StorageConfiguration(provider: .s3, endpoint: endpoint, region: region ?? environment["CCINNBUCKET_IT_REGION"] ?? "us-east-1",
                             addressing: .path, listAPIVersion: listVersion)
    }

    static func client(region: String? = nil, listVersion: ListAPIVersion = .automatic, clock: SigningClock = SigningClock()) -> ObjectStorageClient {
        ObjectStorageClient(configuration: configuration(region: region, listVersion: listVersion), credentials: credentials,
                            transport: URLSessionTransport(), clock: clock)
    }

    /// A fresh bucket that is emptied and removed afterwards.
    static func withScratchBucket(_ body: (ObjectStorageClient, String) async throws -> Void) async throws {
        let client = client()
        let bucket = "ccinn-it-" + UUID().uuidString.prefix(8).lowercased()
        try await client.createBucket(bucket, region: nil)
        do {
            try await body(client, bucket)
        } catch {
            await cleanup(client, bucket)
            throw error
        }
        await cleanup(client, bucket)
    }

    static func cleanup(_ client: ObjectStorageClient, _ bucket: String) async {
        var marker: String?
        repeat {
            guard let page = try? await client.listMultipartUploads(bucket: bucket, prefix: "", keyMarker: marker, uploadIDMarker: nil) else { break }
            for upload in page.uploads { try? await client.abortMultipartUpload(bucket: bucket, key: upload.key, uploadID: upload.uploadID) }
            marker = page.isTruncated ? page.nextKeyMarker : nil
        } while marker != nil
        try? await ObjectEnumerator(storage: client).forEachPage(bucket: bucket, prefix: "") { objects in
            _ = try await client.deleteObjects(bucket: bucket, objects: objects.map { ObjectReference(key: $0.key) })
            return true
        }
        try? await client.deleteBucket(bucket)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func randomFile(at url: URL, bytes: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var generator = SystemRandomNumberGenerator()
        var remaining = bytes
        let block = 4 << 20
        var words = [UInt64](repeating: 0, count: block / 8)
        while remaining > 0 {
            for index in words.indices { words[index] = generator.next() }
            let count = Int(min(Int64(block), remaining))
            try handle.write(contentsOf: words.withUnsafeBytes { Data($0.prefix(count)) })
            remaining -= Int64(count)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("MinIO integration", .enabled(if: IT.enabled), .serialized)
struct MinIOIntegrationTests {
    @Test("lists the seeded buckets and the demo tree with delimiters")
    func bucketsAndTree() async throws {
        let client = IT.client()
        let names = try await client.listBuckets().map(\.name)
        #expect(Set(["ccinn-demo", "ccinn-large", "ccinn-versioned"]).isSubset(of: names))
        let root = try await client.listObjects(ListObjectsRequest(bucket: "ccinn-demo"))
        #expect(Set(["photos/", "special/", "unicode/", "empty-folder/", "docs/"]).isSubset(of: root.commonPrefixes))
        let photos = try await client.listObjects(ListObjectsRequest(bucket: "ccinn-demo", prefix: "photos/"))
        #expect(photos.objects.contains { $0.key == "photos/" && $0.isFolderMarker })
        #expect(photos.commonPrefixes.contains("photos/2024/"))
    }

    @Test("pages through 50,000 keys with continuation tokens")
    func largeListing() async throws {
        let client = IT.client()
        var token: ListToken?
        var count = 0
        var pages = 0
        var previous = ""
        repeat {
            let page = try await client.listObjects(ListObjectsRequest(bucket: "ccinn-large", prefix: "bulk/", token: token))
            for object in page.objects {
                #expect(object.key > previous)
                previous = object.key
            }
            count += page.objects.count
            pages += 1
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil
        #expect(count == IT.bulkCount)
        #expect(pages == (IT.bulkCount + 999) / 1000)
    }

    @Test("forced V1 listing pages with markers")
    func v1Listing() async throws {
        let client = IT.client(listVersion: .v1)
        var token: ListToken?
        var keys: [String] = []
        for _ in 0..<3 {
            let page = try await client.listObjects(ListObjectsRequest(bucket: "ccinn-large", prefix: "bulk/", token: token))
            #expect(page.apiVersion == .v1)
            keys += page.objects.map(\.key)
            token = page.nextToken
        }
        #expect(keys.count == 3_000)
        #expect(Set(keys).count == 3_000)
        if case .marker? = token {} else { Issue.record("expected a marker token") }
    }

    @Test("unicode and special-character keys list, head and download correctly")
    func specialKeys() async throws {
        let client = IT.client()
        let expected = ["special/100% sure & ready (v2).txt", "special/a+b c~d.txt", "special/it's \"quoted\".txt",
                        "special/semi;colon,comma=equals@at#hash.txt"]
        let special = try await client.listObjects(ListObjectsRequest(bucket: "ccinn-demo", prefix: "special/"))
        #expect(special.objects.map(\.key).sorted() == expected.sorted())
        let unicode = try await client.listObjects(ListObjectsRequest(bucket: "ccinn-demo", prefix: "unicode/"))
        #expect(unicode.objects.map(\.key).contains("unicode/naïve café ✓.txt"))
        #expect(unicode.objects.map(\.key).contains("unicode/🪣 bucket.txt"))
        #expect(unicode.commonPrefixes == ["unicode/日本語 フォルダ/"])
        for key in expected + ["unicode/naïve café ✓.txt", "unicode/日本語 フォルダ/メモ.txt"] {
            let metadata = try await client.headObject(bucket: "ccinn-demo", key: key, versionID: nil)
            let data = try await client.getObject(bucket: "ccinn-demo", key: key, versionID: nil, range: nil, maxBytes: 1 << 20)
            #expect(Int64(data.data.count) == metadata.size)
        }
        let url = try await client.presignedURL(bucket: "ccinn-demo", key: "unicode/日本語 フォルダ/メモ.txt", versionID: nil, method: "GET",
                                                expires: 300, responseContentDisposition: nil)
        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self) == "日本語のテキスト\n")
    }

    @Test("object lifecycle: put, head, tags, metadata edit by self-copy, rename, batch delete")
    func objectLifecycle() async throws {
        try await IT.withScratchBucket { client, bucket in
            let key = "dir/hello world+.txt"
            _ = try await client.putObject(bucket: bucket, key: key, body: Data("hello".utf8),
                                           options: ObjectWriteOptions(contentType: "application/octet-stream", userMetadata: ["owner": "ccinn"]),
                                           progress: nil)
            try await client.putObjectTags(bucket: bucket, key: key, versionID: nil, tags: [ObjectTag(key: "env", value: "it & test")])
            #expect(try await client.getObjectTags(bucket: bucket, key: key, versionID: nil) == [ObjectTag(key: "env", value: "it & test")])

            let before = try await client.headObject(bucket: bucket, key: key, versionID: nil)
            var options = before.writeOptions
            options.contentType = "text/plain"
            _ = try await ServerSideCopier(storage: client).copy(CopyObjectRequest(sourceBucket: bucket, sourceKey: key, destinationBucket: bucket,
                                                                                   destinationKey: key, directive: .replace, options: options))
            let after = try await client.headObject(bucket: bucket, key: key, versionID: nil)
            #expect(after.contentType == "text/plain")
            #expect(after.userMetadata["owner"] == "ccinn")

            _ = try await client.copyObject(CopyObjectRequest(sourceBucket: bucket, sourceKey: key, destinationBucket: bucket, destinationKey: "dir/renamed.txt"))
            try await client.deleteObject(bucket: bucket, key: key, versionID: nil)
            await #expect(throws: StorageError.self) { _ = try await client.headObject(bucket: bucket, key: key, versionID: nil) }
            #expect(try await client.getObject(bucket: bucket, key: "dir/renamed.txt", versionID: nil, range: nil, maxBytes: 100).data == Data("hello".utf8))

            for index in 0..<2_500 {
                if index % 250 == 0 { try Task.checkCancellation() }
                _ = try await client.putObject(bucket: bucket, key: String(format: "tmp/%04d", index), body: Data(), options: ObjectWriteOptions(), progress: nil)
            }
            let summary = try await ObjectEnumerator(storage: client).summarize(bucket: bucket, prefix: "tmp/")
            #expect(summary.count == 2_500)
            var deleted = 0
            try await ObjectEnumerator(storage: client).forEachPage(bucket: bucket, prefix: "tmp/") { objects in
                let result = try await client.deleteObjects(bucket: bucket, objects: objects.map { ObjectReference(key: $0.key) })
                deleted += result.deleted.count
                #expect(result.failures.isEmpty)
                return true
            }
            #expect(deleted == 2_500)
            #expect(try await client.listObjects(ListObjectsRequest(bucket: bucket, prefix: "tmp/")).objects.isEmpty)
        }
    }

    @Test("300 MiB multipart upload with 5 MiB parts, then a parallel ranged download that matches byte for byte")
    func multipartRoundTrip() async throws {
        try await IT.withScratchBucket { client, bucket in
            let directory = try IT.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("big.bin")
            try IT.randomFile(at: source, bytes: 300 << 20)
            let limiter = AsyncLimiter(limit: 8)
            let sent = OSAllocatedUnfairLock<Int64>(initialState: 0)
            let started = Date()
            let result = try await ObjectUploader(storage: client, limiter: limiter, partConcurrency: 6).upload(
                file: source, bucket: bucket, key: "videos/big.bin", options: ObjectWriteOptions(contentType: "application/octet-stream"),
                partSize: 5 << 20, progress: { delta in sent.withLock { $0 += delta } }, onCheckpoint: { _ in })
            let uploadSeconds = Date().timeIntervalSince(started)
            #expect(result.eTag?.hasSuffix("-60\"") == true)
            #expect(sent.withLock { $0 } == 300 << 20)
            let metadata = try await client.headObject(bucket: bucket, key: "videos/big.bin", versionID: nil)
            #expect(metadata.size == 300 << 20)

            let destination = directory.appendingPathComponent("downloaded.bin")
            let downloadStarted = Date()
            try await ObjectDownloader(storage: client, limiter: limiter, chunkSize: 8 << 20, concurrency: 6)
                .download(bucket: bucket, key: "videos/big.bin", versionID: nil, to: destination, progress: { _ in })
            let downloadSeconds = Date().timeIntervalSince(downloadStarted)
            #expect(try IT.sha256(of: source) == IT.sha256(of: destination))
            print("multipart 300 MiB: upload \(String(format: "%.1f", uploadSeconds)) s, download \(String(format: "%.1f", downloadSeconds)) s")
        }
    }

    @Test("pause/resume continues a real multipart upload; cancel aborts it")
    func pauseResumeAndAbort() async throws {
        try await IT.withScratchBucket { client, bucket in
            let directory = try IT.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("resume.bin")
            try IT.randomFile(at: source, bytes: 60 << 20)
            let uploader = ObjectUploader(storage: client, limiter: AsyncLimiter(limit: 2), partConcurrency: 2)
            let latest = OSAllocatedUnfairLock<UploadCheckpoint?>(initialState: nil)
            let task = Task {
                try await uploader.upload(file: source, bucket: bucket, key: "resume.bin", options: ObjectWriteOptions(), partSize: 5 << 20,
                                          progress: { _ in }, onCheckpoint: { checkpoint in latest.withLock { $0 = checkpoint } })
            }
            for _ in 0..<500 where (latest.withLock { $0?.parts.count } ?? 0) < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
            task.cancel()
            _ = await task.result
            let checkpoint = try #require(latest.withLock { $0 })
            #expect(checkpoint.parts.count >= 3)
            #expect(checkpoint.parts.count < 12)
            let listed = try await client.listParts(bucket: bucket, key: "resume.bin", uploadID: checkpoint.uploadID)
            #expect(listed.count >= checkpoint.parts.count)

            _ = try await uploader.upload(file: source, bucket: bucket, key: "resume.bin", options: ObjectWriteOptions(), partSize: 5 << 20,
                                          checkpoint: checkpoint, progress: { _ in }, onCheckpoint: { _ in })
            #expect(try await client.headObject(bucket: bucket, key: "resume.bin", versionID: nil).size == 60 << 20)

            // Cancel = abort: no incomplete upload remains.
            let abandoned = try await client.createMultipartUpload(bucket: bucket, key: "abandoned.bin", options: ObjectWriteOptions())
            _ = try await client.uploadPart(bucket: bucket, key: "abandoned.bin", uploadID: abandoned, partNumber: 1, body: Data(count: 5 << 20), progress: nil)
            try await client.abortMultipartUpload(bucket: bucket, key: "abandoned.bin", uploadID: abandoned)
            let uploads = try await client.listMultipartUploads(bucket: bucket, prefix: "", keyMarker: nil, uploadIDMarker: nil)
            #expect(!uploads.uploads.contains { $0.uploadID == abandoned })
        }
    }

    @Test("gzip-encoded objects download byte for byte (no transparent decompression)")
    func contentEncoding() async throws {
        try await IT.withScratchBucket { client, bucket in
            let payload = Data((0..<4096).map { UInt8($0 % 251) })
            _ = try await client.putObject(bucket: bucket, key: "data.gz", body: payload,
                                           options: ObjectWriteOptions(contentType: "application/json", contentEncoding: "gzip"), progress: nil)
            let preview = try await client.getObject(bucket: bucket, key: "data.gz", versionID: nil, range: nil, maxBytes: 1 << 20)
            #expect(preview.data == payload)
            let directory = try IT.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("data.gz")
            try await ObjectDownloader(storage: client, limiter: AsyncLimiter(limit: 2)).download(bucket: bucket, key: "data.gz", versionID: nil,
                                                                                                  to: destination, progress: { _ in })
            #expect(try Data(contentsOf: destination) == payload)
        }
    }

    @Test("versions and delete markers of the versioned bucket")
    func versions() async throws {
        let client = IT.client()
        #expect(try await client.versioningStatus(bucket: "ccinn-versioned") == .enabled)
        let page = try await client.listObjectVersions(VersionListRequest(bucket: "ccinn-versioned", prefix: "", delimiter: nil))
        #expect(page.versions.filter { $0.key == "config.json" }.count >= 3)
        let draft = page.versions.filter { $0.key == "notes/draft.txt" }
        #expect(draft.first?.isDeleteMarker == true)
        #expect(draft.first?.isLatest == true)
        #expect(draft.count >= 3)
        let oldest = try #require(page.versions.last { $0.key == "config.json" })
        let data = try await client.getObject(bucket: "ccinn-versioned", key: "config.json", versionID: oldest.versionID, range: nil, maxBytes: 1024)
        #expect(String(decoding: data.data, as: UTF8.self).contains("\"revision\": 1"))
    }

    @Test("settings documents: versioning, missing lifecycle/policy, ACL")
    func settings() async throws {
        let client = IT.client()
        #expect(try await client.bucketSetting(.versioning, bucket: "ccinn-versioned").state == .configured)
        #expect(try await client.bucketSetting(.lifecycle, bucket: "ccinn-demo").state == .notConfigured)
        #expect(try await client.bucketSetting(.policy, bucket: "ccinn-demo").state == .notConfigured)
        let acl = try await client.bucketSetting(.acl, bucket: "ccinn-demo")
        #expect(acl.state == .configured || acl.state == .unsupported)
        let encryption = try await client.bucketSetting(.encryption, bucket: "ccinn-demo")
        #expect(encryption.state != .configured)
    }

    @Test("a 20-minute clock skew is corrected from the server and the request succeeds")
    func clockSkew() async throws {
        let clock = SigningClock(source: { Date().addingTimeInterval(-1_200) })
        let client = IT.client(clock: clock)
        _ = try await client.listObjects(ListObjectsRequest(bucket: "ccinn-demo", maxKeys: 1))
        #expect(abs(clock.currentOffset - 1_200) < 120)
    }

    @Test("a wrong signing region is corrected from the server's hint")
    func wrongRegion() async throws {
        let client = IT.client(region: "eu-central-1")
        _ = try await client.listObjects(ListObjectsRequest(bucket: "ccinn-demo", maxKeys: 1))
        #expect(client.cachedLocation(of: "ccinn-demo")?.region == "us-east-1")
    }

    @Test("presigned links work until they expire")
    func presignExpiry() async throws {
        let client = IT.client()
        let url = try await client.presignedURL(bucket: "ccinn-demo", key: "docs/README.md", versionID: nil, method: "GET", expires: 1,
                                                responseContentDisposition: "attachment; filename=\"readme.md\"")
        let (_, first) = try await URLSession.shared.data(from: url)
        #expect((first as? HTTPURLResponse)?.statusCode == 200)
        #expect((first as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.contains("readme.md") == true)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let (_, expired) = try await URLSession.shared.data(from: url)
        #expect((expired as? HTTPURLResponse)?.statusCode == 403)
    }
}
