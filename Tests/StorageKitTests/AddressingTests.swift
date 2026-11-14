import Foundation
import StorageSigning
@testable import StorageKit
import Testing

@Suite("Endpoints and addressing")
struct AddressingTests {
    @Test("endpoint parsing accepts hosts, ports and schemes; rejects junk")
    func endpointParsing() {
        #expect(StorageEndpoint(string: "http://127.0.0.1:19900") == StorageEndpoint(scheme: "http", host: "127.0.0.1", port: 19900))
        #expect(StorageEndpoint(string: "oss-cn-hangzhou.aliyuncs.com") == StorageEndpoint(scheme: "https", host: "oss-cn-hangzhou.aliyuncs.com"))
        #expect(StorageEndpoint(string: "https://ACCOUNT.r2.cloudflarestorage.com/")?.host == "account.r2.cloudflarestorage.com")
        #expect(StorageEndpoint(string: "ftp://example.com") == nil)
        #expect(StorageEndpoint(string: "https://user:pass@example.com") == nil)
        #expect(StorageEndpoint(string: "https://exa mple.com") == nil)
        #expect(StorageEndpoint(string: "") == nil)
        #expect(StorageEndpoint(string: "http://[::1]:9000")?.host == "[::1]")
        #expect(StorageEndpoint(string: "http://example.com:0") == nil)
    }

    @Test("S3 custom endpoint, path style")
    func s3PathStyle() throws {
        let dialect = S3Dialect(configuration: Fixtures.minio)
        let target = try dialect.resolve(bucket: "ccinn-demo", key: "a b/c+d.txt", location: nil)
        #expect(target.url(encodedQuery: "")?.absoluteString == "http://127.0.0.1:19900/ccinn-demo/a%20b/c%2Bd.txt")
        #expect(target.hostHeader == "127.0.0.1:19900")
        #expect(target.signingRegion == "us-east-1")
        let bucketLevel = try dialect.resolve(bucket: "ccinn-demo", key: nil, location: nil)
        #expect(bucketLevel.path == "/ccinn-demo")
        let service = try dialect.resolve(bucket: nil, key: nil, location: nil)
        #expect(service.path == "/")
    }

    @Test("S3 on AWS: regional virtual-hosted URLs, dotted buckets fall back to path style")
    func s3AWS() throws {
        let dialect = S3Dialect(configuration: Fixtures.aws)
        let virtual = try dialect.resolve(bucket: "photos", key: "2024/x.jpg", location: BucketLocation(region: "eu-west-1"))
        #expect(virtual.url(encodedQuery: "")?.absoluteString == "https://photos.s3.eu-west-1.amazonaws.com/2024/x.jpg")
        #expect(virtual.signingRegion == "eu-west-1")
        let dotted = try dialect.resolve(bucket: "my.dotted.bucket", key: "k", location: nil)
        #expect(dotted.url(encodedQuery: "")?.absoluteString == "https://s3.us-east-1.amazonaws.com/my.dotted.bucket/k")
        let china = try dialect.resolve(bucket: "b-cn", key: "k", location: BucketLocation(region: "cn-north-1"))
        #expect(china.host == "b-cn.s3.cn-north-1.amazonaws.com.cn")
        let list = try dialect.resolve(bucket: nil, key: nil, location: nil)
        #expect(list.host == "s3.us-east-1.amazonaws.com")
    }

    @Test("virtual-hosted style is never used with IP or localhost endpoints")
    func virtualNeedsDNS() throws {
        var configuration = Fixtures.minio
        configuration.addressing = .virtualHosted
        let target = try S3Dialect(configuration: configuration).resolve(bucket: "demo", key: "k", location: nil)
        #expect(target.host == "127.0.0.1")
        #expect(target.path == "/demo/k")
        configuration.endpoint = StorageEndpoint(scheme: "https", host: "minio.example.com")
        let named = try S3Dialect(configuration: configuration).resolve(bucket: "demo", key: "k", location: nil)
        #expect(named.host == "demo.minio.example.com")
    }

    @Test("AWS host region extraction", arguments: [
        ("s3.eu-west-1.amazonaws.com", "eu-west-1"), ("bucket.s3.ap-south-1.amazonaws.com", "ap-south-1"),
        ("s3-us-west-2.amazonaws.com", "us-west-2"), ("s3.amazonaws.com", "us-east-1"),
        ("b.s3.dualstack.eu-central-1.amazonaws.com", "eu-central-1"), ("s3.cn-north-1.amazonaws.com.cn", "cn-north-1"),
    ])
    func awsRegionFromHost(_ host: String, _ region: String) {
        #expect(S3Dialect.region(fromAWSHost: host) == region)
    }

    @Test("OSS endpoints: public, internal, accelerate, path style and custom domain")
    func ossResolution() throws {
        let publicTarget = try OSSDialect(configuration: Fixtures.oss).resolve(bucket: "bkt", key: "dir/示例.txt", location: nil)
        #expect(publicTarget.url(encodedQuery: "")?.absoluteString == "https://bkt.oss-cn-hangzhou.aliyuncs.com/dir/%E7%A4%BA%E4%BE%8B.txt")
        #expect(publicTarget.signingRegion == "cn-hangzhou")

        var internalConfiguration = Fixtures.oss
        internalConfiguration.ossEndpointKind = .internal
        #expect(try OSSDialect(configuration: internalConfiguration).resolve(bucket: "bkt", key: "k", location: nil).host
            == "bkt.oss-cn-hangzhou-internal.aliyuncs.com")

        var accelerate = Fixtures.oss
        accelerate.ossEndpointKind = .accelerate
        let accelerated = try OSSDialect(configuration: accelerate).resolve(bucket: "bkt", key: "k", location: nil)
        #expect(accelerated.host == "bkt.oss-accelerate.aliyuncs.com")
        #expect(accelerated.signingRegion == "cn-hangzhou")

        var custom = Fixtures.oss
        custom.endpoint = StorageEndpoint(scheme: "https", host: "cdn.example.com")
        custom.customDomainBucket = "bkt"
        let cname = try OSSDialect(configuration: custom).resolve(bucket: "bkt", key: "a/b.txt", location: nil)
        #expect(cname.url(encodedQuery: "")?.absoluteString == "https://cdn.example.com/a/b.txt")

        var pathStyle = Fixtures.oss
        pathStyle.addressing = .path
        #expect(try OSSDialect(configuration: pathStyle).resolve(bucket: "bkt", key: nil, location: nil).path == "/bkt/")
    }

    @Test("OSS bucket in another region uses that region's endpoint and signing region")
    func ossRelocated() throws {
        let dialect = OSSDialect(configuration: Fixtures.oss)
        let target = try dialect.resolve(bucket: "bkt", key: "k", location: BucketLocation(region: "cn-shanghai", endpointHost: "oss-cn-shanghai.aliyuncs.com"))
        #expect(target.host == "bkt.oss-cn-shanghai.aliyuncs.com")
        #expect(target.signingRegion == "cn-shanghai")
        #expect(OSSDialect.region(fromHost: "oss-cn-shanghai-internal.aliyuncs.com") == "cn-shanghai")
        #expect(OSSDialect.region(fromHost: "bucket.oss-ap-southeast-1.aliyuncs.com") == "ap-southeast-1")
        #expect(OSSDialect.region(fromHost: "oss-accelerate.aliyuncs.com") == nil)
        #expect(OSSDialect.normalizedRegion("oss-cn-beijing") == "cn-beijing")
    }

    @Test("bucket name rules", arguments: [
        ("my-bucket", StorageProvider.s3, true), ("my.bucket", .s3, true), ("my.bucket", .oss, false), ("My_Bucket", .s3, false),
        ("ab", .s3, false), ("192.168.1.1", .s3, false), ("-start", .oss, false), ("end-", .oss, false), ("xn--abc", .s3, false),
        ("a..b", .s3, false), (String(repeating: "a", count: 64), .s3, false),
    ])
    func bucketNames(_ name: String, _ provider: StorageProvider, _ valid: Bool) {
        #expect(BucketNaming.violations(name, provider: provider).isEmpty == valid)
    }
}
