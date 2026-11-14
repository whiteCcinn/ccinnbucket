import Foundation
import os
import StorageSigning
@testable import StorageKit
import Testing

@Suite("Operations: request construction and decoding")
struct OperationTests {
    @Test("ListObjectsV2 query and URL-decoded keys (S3 form encoding)")
    func listV2() async throws {
        let body = """
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name><Prefix>special%2F</Prefix><KeyCount>3</KeyCount>
        <MaxKeys>1000</MaxKeys><Delimiter>%2F</Delimiter><IsTruncated>true</IsTruncated><NextContinuationToken>tok/en+==</NextContinuationToken>
        <Contents><Key>special%2Fa%2Bb+c%7Ed.txt</Key><LastModified>2026-11-14T03:03:33.907Z</LastModified><ETag>&#34;abc&#34;</ETag><Size>15</Size><StorageClass>STANDARD</StorageClass></Contents>
        <Contents><Key>special%2F</Key><Size>0</Size></Contents>
        <Contents><Key>special%2F%01ctrl</Key><Size>1</Size></Contents>
        <CommonPrefixes><Prefix>special%2Fsub+dir%2F</Prefix></CommonPrefixes><EncodingType>url</EncodingType></ListBucketResult>
        """
        let transport = FakeTransport(responses: [Fixtures.xml(body)])
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        let page = try await client.listObjects(ListObjectsRequest(bucket: "b", prefix: "special/", token: .continuation("prev token")))
        let query = Fixtures.query(try #require(transport.requests.first))
        #expect(query["list-type"] == "2")
        #expect(query["prefix"] == "special/")
        #expect(query["delimiter"] == "/")
        #expect(query["encoding-type"] == "url")
        #expect(query["max-keys"] == "1000")
        #expect(query["continuation-token"] == "prev token")
        #expect(page.objects.map(\.key) == ["special/a+b c~d.txt", "special/", "special/\u{1}ctrl"])
        #expect(page.objects.first?.size == 15)
        #expect(page.objects.first?.eTag == "\"abc\"")
        #expect(page.objects[1].isFolderMarker)
        #expect(page.commonPrefixes == ["special/sub dir/"])
        #expect(page.nextToken == .continuation("tok/en+=="))
        #expect(page.apiVersion == .v2)
    }

    @Test("OSS listings decode %20 and keep literal plus signs")
    func ossDecoding() async throws {
        let body = "<ListBucketResult><KeyCount>1</KeyCount><IsTruncated>false</IsTruncated><EncodingType>url</EncodingType><Contents><Key>a+b%20c</Key><Size>1</Size></Contents></ListBucketResult>"
        let client = Fixtures.client(Fixtures.oss, transport: FakeTransport(responses: [Fixtures.xml(body)]))
        let page = try await client.listObjects(ListObjectsRequest(bucket: "bkt"))
        #expect(page.objects.map(\.key) == ["a+b c"])
    }

    @Test("keys are not decoded when the server ignored encoding-type")
    func noEncodingType() async throws {
        let body = "<ListBucketResult><KeyCount>1</KeyCount><IsTruncated>false</IsTruncated><Contents><Key>100%+sure</Key><Size>1</Size></Contents></ListBucketResult>"
        let client = Fixtures.client(Fixtures.minio, transport: FakeTransport(responses: [Fixtures.xml(body)]))
        #expect(try await client.listObjects(ListObjectsRequest(bucket: "b")).objects.map(\.key) == ["100%+sure"])
    }

    @Test("falls back to V1 listing when V2 is not implemented, and remembers")
    func v1Fallback() async throws {
        let v1 = """
        <ListBucketResult><Marker></Marker><IsTruncated>true</IsTruncated><EncodingType>url</EncodingType>
        <Contents><Key>a.txt</Key><Size>1</Size></Contents><Contents><Key>b.txt</Key><Size>1</Size></Contents></ListBucketResult>
        """
        let transport = FakeTransport { request, _ in
            if Fixtures.query(request)["list-type"] == "2" { return Fixtures.error("NotImplemented", status: 501) }
            return Fixtures.xml(v1)
        }
        let client = Fixtures.client(Fixtures.minio, transport: transport, retry: .none)
        let first = try await client.listObjects(ListObjectsRequest(bucket: "b"))
        #expect(first.apiVersion == .v1)
        #expect(first.nextToken == .marker("b.txt"))
        let second = try await client.listObjects(ListObjectsRequest(bucket: "b", token: first.nextToken))
        #expect(second.apiVersion == .v1)
        #expect(Fixtures.query(transport.requests[2])["marker"] == "b.txt")
        #expect(client.effectiveListAPIVersion == .v1)
        #expect(transport.requests.count == 3)
    }

    @Test("a server that silently answers V2 requests in V1 form is detected")
    func silentV1() async throws {
        let v1 = "<ListBucketResult><Marker></Marker><NextMarker>photos%2F</NextMarker><IsTruncated>true</IsTruncated><EncodingType>url</EncodingType><CommonPrefixes><Prefix>photos%2F</Prefix></CommonPrefixes></ListBucketResult>"
        let client = Fixtures.client(Fixtures.minio, transport: FakeTransport(responses: [Fixtures.xml(v1)]))
        let page = try await client.listObjects(ListObjectsRequest(bucket: "b"))
        #expect(page.apiVersion == .v1)
        #expect(page.nextToken == .marker("photos/"))
        #expect(client.effectiveListAPIVersion == .v1)
    }

    @Test("versions and delete markers keep document order")
    func versions() async throws {
        let body = """
        <ListVersionsResult><IsTruncated>true</IsTruncated><NextKeyMarker>notes%2Fdraft.txt</NextKeyMarker><NextVersionIdMarker>v1</NextVersionIdMarker><EncodingType>url</EncodingType>
        <DeleteMarker><Key>notes%2Fdraft.txt</Key><VersionId>v3</VersionId><IsLatest>true</IsLatest><LastModified>2026-11-14T03:07:50Z</LastModified></DeleteMarker>
        <Version><Key>notes%2Fdraft.txt</Key><VersionId>v2</VersionId><IsLatest>false</IsLatest><Size>6</Size><ETag>"x"</ETag></Version>
        <Version><Key>notes%2Fdraft.txt</Key><VersionId>v1</VersionId><IsLatest>false</IsLatest><Size>6</Size></Version>
        </ListVersionsResult>
        """
        let transport = FakeTransport(responses: [Fixtures.xml(body)])
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        let page = try await client.listObjectVersions(VersionListRequest(bucket: "b", prefix: "notes/", keyMarker: "k", versionIDMarker: "vm"))
        #expect(page.versions.map(\.versionID) == ["v3", "v2", "v1"])
        #expect(page.versions[0].isDeleteMarker && page.versions[0].isLatest)
        #expect(page.nextKeyMarker == "notes/draft.txt")
        let query = Fixtures.query(try #require(transport.requests.first))
        #expect(query.keys.contains("versions"))
        #expect(query["key-marker"] == "k")
        #expect(query["version-id-marker"] == "vm")
    }

    @Test("DeleteObjects: escaped XML, Content-MD5, 1,000-key batches, per-key fallback for unrepresentable keys")
    func deleteObjects() async throws {
        let transport = FakeTransport { request, _ in
            if request.method == "POST" {
                return Fixtures.xml("<DeleteResult><Error><Key>keep&amp;me</Key><Code>AccessDenied</Code><Message>no</Message></Error></DeleteResult>")
            }
            return HTTPResponse(statusCode: 204)
        }
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        var objects = (0..<2_500).map { ObjectReference(key: "k\($0)") }
        objects.append(ObjectReference(key: "keep&me"))
        objects.append(ObjectReference(key: "bad\u{1}key", versionID: "v9"))
        let result = try await client.deleteObjects(bucket: "b", objects: objects)
        let posts = transport.requests.filter { $0.method == "POST" }
        #expect(posts.count == 3)
        let first = try #require(posts.first)
        let body = try #require(first.body)
        #expect(first.header("Content-MD5") == Hashing.md5Base64(body))
        #expect(String(decoding: posts[2].body ?? Data(), as: UTF8.self).contains("<Key>keep&amp;me</Key>"))
        let deletes = transport.requests.filter { $0.method == "DELETE" }
        #expect(deletes.count == 1)
        #expect(Fixtures.query(try #require(deletes.first))["versionId"] == "v9")
        #expect(deletes.first?.url.absoluteString.contains("bad%01key") == true)
        #expect(result.failures.map(\.key) == ["keep&me"])
        #expect(result.deleted.count == 2_501)
    }

    @Test("CopyObject encodes the source, sets the directive and dialect headers")
    func copyObject() async throws {
        let transport = FakeTransport(responses: [Fixtures.xml("<CopyObjectResult><ETag>\"new\"</ETag></CopyObjectResult>", headers: ["x-amz-version-id": "v2"])])
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        let result = try await client.copyObject(CopyObjectRequest(sourceBucket: "src", sourceKey: "a b/ü+.txt", sourceVersionID: "v/1",
                                                                   destinationBucket: "dst", destinationKey: "c.txt", directive: .replace,
                                                                   options: ObjectWriteOptions(contentType: "text/html", userMetadata: ["Owner": "ccinn"])))
        let request = try #require(transport.requests.first)
        #expect(request.header("x-amz-copy-source") == "/src/a%20b/%C3%BC%2B.txt?versionId=v%2F1")
        #expect(request.header("x-amz-metadata-directive") == "REPLACE")
        #expect(request.header("Content-Type") == "text/html")
        #expect(request.header("x-amz-meta-owner") == "ccinn")
        #expect(result.eTag == "\"new\"")
        #expect(result.versionID == "v2")

        let ossTransport = FakeTransport(responses: [Fixtures.xml("<CopyObjectResult><ETag>\"e\"</ETag></CopyObjectResult>")])
        _ = try await Fixtures.client(Fixtures.oss, transport: ossTransport)
            .copyObject(CopyObjectRequest(sourceBucket: "s", sourceKey: "k", destinationBucket: "d", destinationKey: "k2",
                                          options: ObjectWriteOptions(storageClass: "IA")))
        let ossRequest = try #require(ossTransport.requests.first)
        #expect(ossRequest.header("x-oss-copy-source") == "/s/k")
        #expect(ossRequest.header("x-oss-storage-class") == "IA")
        #expect(ossRequest.header("x-oss-metadata-directive") == "COPY")
        #expect(ossRequest.header("Authorization")?.hasPrefix("OSS4-HMAC-SHA256 Credential=") == true)
    }

    @Test("HEAD maps headers to metadata (S3 and OSS prefixes)")
    func headObject() async throws {
        let headers = ["Content-Length": "150", "Content-Type": "application/json", "ETag": "\"81af\"", "Last-Modified": "Sat, 14 Nov 2026 03:03:34 GMT",
                       "x-amz-meta-owner": "ccinn", "x-amz-tagging-count": "2", "x-amz-version-id": "v1", "x-amz-server-side-encryption": "AES256"]
        let client = Fixtures.client(Fixtures.minio, transport: FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: headers)]))
        let metadata = try await client.headObject(bucket: "b", key: "data/config.json", versionID: nil)
        #expect(metadata.size == 150)
        #expect(metadata.userMetadata == ["owner": "ccinn"])
        #expect(metadata.tagCount == 2)
        #expect(metadata.versionID == "v1")
        #expect(metadata.serverSideEncryption == "AES256")
        #expect(metadata.lastModified == Date(timeIntervalSince1970: 1_794_625_414))

        let ossHeaders = ["Content-Length": "9", "x-oss-meta-team": "storage", "x-oss-storage-class": "IA", "x-oss-object-type": "Multipart"]
        let ossClient = Fixtures.client(Fixtures.oss, transport: FakeTransport(responses: [HTTPResponse(statusCode: 200, headers: ossHeaders)]))
        let ossMetadata = try await ossClient.headObject(bucket: "bkt", key: "k", versionID: nil)
        #expect(ossMetadata.userMetadata == ["team": "storage"])
        #expect(ossMetadata.storageClass == "IA")
        #expect(ossMetadata.objectType == "Multipart")
    }

    @Test("ranged preview GET is bounded and reports the total size")
    func rangedPreview() async throws {
        let transport = FakeTransport(responses: [HTTPResponse(statusCode: 206, headers: ["Content-Range": "bytes 0-9/2048000000", "Content-Length": "10"],
                                                               body: Data("0123456789".utf8))])
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        let result = try await client.getObject(bucket: "b", key: "big.log", versionID: nil, range: ByteRange(first: 0, last: 9), maxBytes: 64)
        #expect(result.totalSize == 2_048_000_000)
        #expect(result.isPartial)
        let request = try #require(transport.requests.first)
        #expect(request.header("Range") == "bytes=0-9")
        #expect(Fixtures.query(request)["response-content-encoding"] == "identity")
    }

    @Test("download writes only successful bodies to the file and validates Content-Range")
    func downloadToFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-test-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x2E, count: 20))
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = open(url.path, O_RDWR)
        defer { close(descriptor) }

        let ok = FakeTransport(responses: [HTTPResponse(statusCode: 206, headers: ["Content-Range": "bytes 10-14/20", "ETag": "\"e\""], body: Data("HELLO".utf8))])
        _ = try await Fixtures.client(Fixtures.minio, transport: ok).downloadObject(
            bucket: "b", key: "k", versionID: nil, range: ByteRange(first: 10, last: 14), ifMatch: "\"e\"", descriptor: descriptor, fileOffset: 10, progress: nil)
        #expect(ok.requests.first?.header("If-Match") == "\"e\"")
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "..........HELLO.....")

        let missing = FakeTransport(responses: [Fixtures.error("NoSuchKey", status: 404)])
        await #expect(throws: StorageError.self) {
            _ = try await Fixtures.client(Fixtures.minio, transport: missing).downloadObject(
                bucket: "b", key: "k", versionID: nil, range: ByteRange(first: 0, last: 4), ifMatch: nil, descriptor: descriptor, fileOffset: 0, progress: nil)
        }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "..........HELLO.....", "error bodies never reach the file")

        let ignoredRange = FakeTransport(responses: [HTTPResponse(statusCode: 200, body: Data("WHOLE OBJECT".utf8))])
        await #expect(throws: StorageError.self) {
            _ = try await Fixtures.client(Fixtures.minio, transport: ignoredRange, retry: .none).downloadObject(
                bucket: "b", key: "k", versionID: nil, range: ByteRange(first: 5, last: 9), ifMatch: nil, descriptor: descriptor, fileOffset: 5, progress: nil)
        }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "..........HELLO.....")
    }

    @Test("bucket listing pages (OSS marker) and remembers bucket locations")
    func listBuckets() async throws {
        let first = """
        <ListAllMyBucketsResult><IsTruncated>true</IsTruncated><NextMarker>b2</NextMarker><Buckets>
        <Bucket><Name>b1</Name><CreationDate>2024-01-01T00:00:00.000Z</CreationDate><Location>oss-cn-shanghai</Location><Region>cn-shanghai</Region>
        <ExtranetEndpoint>oss-cn-shanghai.aliyuncs.com</ExtranetEndpoint></Bucket></Buckets></ListAllMyBucketsResult>
        """
        let second = "<ListAllMyBucketsResult><IsTruncated>false</IsTruncated><Buckets><Bucket><Name>b2</Name></Bucket></Buckets></ListAllMyBucketsResult>"
        let transport = FakeTransport(responses: [Fixtures.xml(first), Fixtures.xml(second)])
        let client = Fixtures.client(Fixtures.oss, transport: transport)
        let buckets = try await client.listBuckets()
        #expect(buckets.map(\.name) == ["b1", "b2"])
        #expect(Fixtures.query(transport.requests[1])["marker"] == "b2")
        #expect(client.cachedLocation(of: "b1") == BucketLocation(region: "cn-shanghai", endpointHost: "oss-cn-shanghai.aliyuncs.com"))
    }

    @Test("bucket settings: not configured, unsupported, failed, configured")
    func settings() async throws {
        let transport = FakeTransport { request, _ in
            let query = Fixtures.query(request)
            if query.keys.contains("lifecycle") { return Fixtures.error("NoSuchLifecycleConfiguration", status: 404) }
            if query.keys.contains("cors") { return Fixtures.error("NotImplemented", status: 501) }
            if query.keys.contains("encryption") { return Fixtures.error("AccessDenied", status: 403) }
            if query.keys.contains("policy") {
                return HTTPResponse(statusCode: 200, body: Data(#"{"Version":"2012-10-17","Statement":[{"Sid":"Public","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]}"#.utf8))
            }
            if query.keys.contains("acl") {
                return Fixtures.xml("""
                <AccessControlPolicy><Owner><ID>o1</ID><DisplayName>owner</DisplayName></Owner><AccessControlList>
                <Grant><Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group"><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant>
                </AccessControlList></AccessControlPolicy>
                """)
            }
            return Fixtures.xml("<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>")
        }
        let client = Fixtures.client(Fixtures.minio, transport: transport, retry: .none)
        #expect(try await client.bucketSetting(.lifecycle, bucket: "b").state == .notConfigured)
        #expect(try await client.bucketSetting(.cors, bucket: "b").state == .unsupported)
        let encryption = try await client.bucketSetting(.encryption, bucket: "b")
        #expect(encryption.state == .failed)
        #expect(encryption.message?.contains("AccessDenied") == true)
        let policy = try await client.bucketSetting(.policy, bucket: "b")
        #expect(policy.items.first?.title == "Public")
        #expect(policy.raw.contains("\"Effect\" : \"Allow\""))
        let acl = try await client.bucketSetting(.acl, bucket: "b")
        #expect(acl.items.contains { $0.title == "Everyone (public)" })
        #expect(try await client.versioningStatus(bucket: "b") == .suspended)
    }

    @Test("lifecycle and CORS parsers")
    func parsers() throws {
        let lifecycle = try XMLReader.parse(Data("""
        <LifecycleConfiguration><Rule><ID>logs</ID><Filter><Prefix>logs/</Prefix></Filter><Status>Enabled</Status>
        <Transition><Days>30</Days><StorageClass>STANDARD_IA</StorageClass></Transition><Expiration><Days>365</Days></Expiration>
        <AbortIncompleteMultipartUpload><DaysAfterInitiation>7</DaysAfterInitiation></AbortIncompleteMultipartUpload></Rule></LifecycleConfiguration>
        """.utf8))
        let rule = try #require(BucketSettingParsers.lifecycle(lifecycle).first)
        #expect(rule.title == "logs")
        #expect(rule.fields.contains(SettingField("Applies to", "Prefix logs/")))
        #expect(rule.fields.contains(SettingField("Transition", "To STANDARD_IA after 30 days")))
        #expect(rule.fields.contains(SettingField("Incomplete uploads", "Abort after 7 days")))
        let cors = try XMLReader.parse(Data("<CORSConfiguration><CORSRule><AllowedOrigin>*</AllowedOrigin><AllowedMethod>GET</AllowedMethod><AllowedMethod>PUT</AllowedMethod><MaxAgeSeconds>300</MaxAgeSeconds></CORSRule></CORSConfiguration>".utf8))
        #expect(BucketSettingParsers.cors(cors).first?.fields.contains(SettingField("Methods", "GET, PUT")) == true)
    }

    @Test("presigned URLs for S3 and OSS, expiry bounds enforced")
    func presign() async throws {
        let s3 = Fixtures.client(Fixtures.minio, transport: FakeTransport(responses: []))
        let url = try await s3.presignedURL(bucket: "ccinn-demo", key: "a b.txt", versionID: "v1", method: "GET", expires: 3600,
                                            responseContentDisposition: "attachment")
        #expect(url.absoluteString.hasPrefix("http://127.0.0.1:19900/ccinn-demo/a%20b.txt?versionId=v1&response-content-disposition=attachment&X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        #expect(url.absoluteString.contains("X-Amz-Expires=3600"))
        await #expect(throws: StorageError.self) {
            _ = try await s3.presignedURL(bucket: "b", key: "k", versionID: nil, method: "GET", expires: 8 * 86_400, responseContentDisposition: nil)
        }
        let oss = Fixtures.client(Fixtures.oss, transport: FakeTransport(responses: []))
        let ossURL = try await oss.presignedURL(bucket: "bkt", key: "k", versionID: nil, method: "GET", expires: 60, responseContentDisposition: nil)
        #expect(ossURL.host == "bkt.oss-cn-hangzhou.aliyuncs.com")
        #expect(ossURL.absoluteString.contains("x-oss-signature="))
        var v1 = Fixtures.oss
        v1.ossSignatureVersion = .v1
        let v1URL = try await Fixtures.client(v1, transport: FakeTransport(responses: [])).presignedURL(
            bucket: "bkt", key: "k", versionID: nil, method: "GET", expires: 60, responseContentDisposition: nil)
        #expect(v1URL.absoluteString.contains("Expires=1794645075"))
    }

    @Test("tags round-trip through XML and are validated")
    func tags() async throws {
        let transport = FakeTransport(responses: [HTTPResponse(statusCode: 200),
                                                  Fixtures.xml("<Tagging><TagSet><Tag><Key>env</Key><Value>demo &amp; test</Value></Tag></TagSet></Tagging>")])
        let client = Fixtures.client(Fixtures.minio, transport: transport)
        try await client.putObjectTags(bucket: "b", key: "k", versionID: nil, tags: [ObjectTag(key: "env", value: "demo & test")])
        #expect(String(decoding: transport.requests[0].body ?? Data(), as: UTF8.self).contains("<Value>demo &amp; test</Value>"))
        #expect(try await client.getObjectTags(bucket: "b", key: "k", versionID: nil) == [ObjectTag(key: "env", value: "demo & test")])
        await #expect(throws: StorageError.self) {
            try await client.putObjectTags(bucket: "b", key: "k", versionID: nil, tags: (0..<11).map { ObjectTag(key: "k\($0)", value: "") })
        }
    }
}
