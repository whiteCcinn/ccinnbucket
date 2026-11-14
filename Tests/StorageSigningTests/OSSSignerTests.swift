import Foundation
import StorageSigning
import Testing

@Suite("Alibaba Cloud OSS signatures")
struct OSSSignerTests {
    private static func request(method: String, host: String, bucket: String?, key: String?,
                                query: [[String]]?, headers: [[String]]?) -> SigningRequest {
        let path = "/" + (key ?? "")
        return SigningRequest(method: method, host: host, path: path, query: Vectors.parameters(query),
                              headers: Vectors.headers(headers), bucket: bucket, key: key)
    }

    @Test("V4 fixtures were produced by the official SDKs")
    func fixturesLoaded() throws {
        let v4 = try #require(Vectors.ossV4)
        #expect(v4.sdks["alibabacloud-oss-v2"] != nil)
        #expect(v4.cases.count >= 8)
        #expect(try #require(Vectors.ossV1).sdks["oss2"] != nil)
    }

    @Test("V4 header signatures and presigned URLs match alibabacloud-oss-v2", arguments: Vectors.ossV4?.cases ?? [])
    func v4(_ vector: OSSV4Case) throws {
        let file = try #require(Vectors.ossV4)
        let credentials = try file.signingCredentials(vector.credentials)
        let request = Self.request(method: vector.method, host: vector.host, bucket: vector.bucket, key: vector.key,
                                   query: vector.query, headers: vector.headers)
        #expect(PercentEncoding.encodePath(request.path) == vector.expected.encodedPath)
        let signer = OSSV4Signer(credentials: credentials, region: vector.region)
        let date = try Vectors.date(vector.timestamp)
        let additional = Set(vector.additionalHeaders ?? [])
        if let expires = vector.expires {
            let result = try signer.presign(request, expires: expires, date: date, additionalHeaders: additional)
            #expect(result.stringToSign == vector.expected.stringToSign)
            let url = "\(vector.scheme)://\(vector.host)\(PercentEncoding.encodePath(request.path))?\(result.queryString)"
            #expect(url == vector.expected.url)
        } else {
            let result = signer.sign(request, date: date, additionalHeaders: additional)
            #expect(result.stringToSign == vector.expected.stringToSign)
            #expect(result.header("Authorization") == vector.expected.authorization)
            #expect(result.header("x-oss-date") == vector.expected.ossDate)
            #expect(result.header("x-oss-content-sha256") == vector.expected.contentSHA256)
            #expect(result.header("Date") == vector.expected.date)
            #expect(result.header("x-oss-security-token") == vector.expected.securityToken)
            let wireQuery = vector.url.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            #expect(PercentEncoding.queryString(request.query) == wireQuery)
        }
    }

    @Test("V1 header signatures and presigned URLs match oss2", arguments: Vectors.ossV1?.cases ?? [])
    func v1(_ vector: OSSV1Case) throws {
        let file = try #require(Vectors.ossV1)
        let credentials = try file.signingCredentials(vector.credentials)
        let request = Self.request(method: vector.method, host: vector.host, bucket: vector.bucket?.nilIfEmpty,
                                   key: vector.key?.nilIfEmpty, query: vector.query, headers: vector.headers)
        let signer = OSSV1Signer(credentials: credentials)
        if let expiresAt = vector.expiresAt {
            let result = signer.presign(request, expiresAt: expiresAt)
            #expect(result.signature == vector.expected.signature)
            let url = "\(vector.scheme)://\(vector.host)\(PercentEncoding.encodePath(request.path))?\(result.queryString)"
            #expect(url == vector.expected.url)
        } else {
            let dateText = try #require(vector.expected.date)
            let date = try #require(OSSV1Signer.parseHTTPDate(dateText))
            let result = signer.sign(request, date: date)
            #expect(result.header("Authorization") == vector.expected.authorization)
            #expect(result.header("Date") == vector.expected.date)
            #expect(result.header("x-oss-security-token") == vector.expected.securityToken)
        }
    }

    @Test("V1 signs only the documented sub-resources")
    func v1SubresourceSelection() {
        let signer = OSSV1Signer(credentials: SigningCredentials(accessKeyID: "id", secretAccessKey: "secret"))
        let request = SigningRequest(method: "GET", host: "b.oss-cn-hangzhou.aliyuncs.com", path: "/k",
                                     query: [QueryParameter("prefix", "x"), QueryParameter("acl", ""), QueryParameter("uploadId", "1")],
                                     bucket: "b", key: "k")
        #expect(signer.canonicalResource(request) == "/b/k?acl&uploadId=1")
        let service = SigningRequest(method: "GET", host: "oss-cn-hangzhou.aliyuncs.com", path: "/")
        #expect(signer.canonicalResource(service) == "/")
        let bucketOnly = SigningRequest(method: "GET", host: "b.oss-cn-hangzhou.aliyuncs.com", path: "/", bucket: "b")
        #expect(signer.canonicalResource(bucketOnly) == "/b/")
    }

    @Test("V4 presign rejects expiries outside 1 s … 7 days", arguments: [0, 604_801])
    func v4ExpiryBounds(_ expires: Int) {
        let signer = OSSV4Signer(credentials: SigningCredentials(accessKeyID: "id", secretAccessKey: "secret"), region: "cn-hangzhou")
        let request = SigningRequest(method: "GET", host: "b.oss-cn-hangzhou.aliyuncs.com", path: "/k", bucket: "b", key: "k")
        #expect(throws: SigningError.self) { try signer.presign(request, expires: expires, date: Date(timeIntervalSince1970: 0)) }
    }

    @Test("HTTP dates are RFC 1123 in GMT regardless of locale")
    func httpDate() {
        #expect(OSSV1Signer.httpDate(Date(timeIntervalSince1970: 1_794_645_015)) == "Sat, 14 Nov 2026 08:30:15 GMT")
        #expect(OSSV1Signer.httpDate(Date(timeIntervalSince1970: 1_794_648_615)) == "Sat, 14 Nov 2026 09:30:15 GMT")
        #expect(OSSV1Signer.parseHTTPDate("Sat, 14 Nov 2026 08:30:15 GMT") == Date(timeIntervalSince1970: 1_794_645_015))
        #expect(OSSV1Signer.parseHTTPDate("not a date") == nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
