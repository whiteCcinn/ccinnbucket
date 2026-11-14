import CryptoKit
import Foundation
import StorageSigning
import Testing

@Suite("AWS Signature V4")
struct AWSSigV4Tests {
    @Test("fixtures were produced by the official SDK")
    func fixturesLoaded() throws {
        let file = try #require(Vectors.awsHeader)
        #expect(file.sdks["botocore"] != nil)
        #expect(file.cases.count >= 10)
        #expect(try #require(Vectors.awsPresign).cases.isEmpty == false)
    }

    @Test("header signatures match botocore (and the AWS documentation)", arguments: Vectors.awsHeader?.cases ?? [])
    func headerSignature(_ vector: AWSHeaderCase) throws {
        let file = try #require(Vectors.awsHeader)
        let credentials = try file.signingCredentials(vector.credentials)
        let excluded: Set<String> = ["x-amz-date", "x-amz-content-sha256"]
        let request = SigningRequest(method: vector.method, host: vector.host, path: vector.path,
                                     query: Vectors.parameters(vector.query),
                                     headers: Vectors.headers(vector.headers, excluding: excluded))
        let payloadHash: String
        if vector.unsignedPayload == true {
            payloadHash = PayloadHash.unsigned
        } else {
            payloadHash = PayloadHash.sha256Hex(Data((vector.body ?? "").utf8))
        }
        if let expectedHash = vector.expected.payloadHash {
            #expect(payloadHash == expectedHash)
        }
        let signer = AWSSigV4Signer(credentials: credentials, region: vector.region)
        let result = signer.sign(request, payloadHash: payloadHash, date: try Vectors.date(vector.timestamp))

        #expect(PercentEncoding.encodePath(vector.path) == vector.expected.encodedPath)
        #expect(result.canonicalRequest == vector.expected.canonicalRequest)
        #expect(result.stringToSign == vector.expected.stringToSign)
        #expect(result.signature == vector.expected.signature)
        #expect(result.header("Authorization") == vector.expected.authorization)
        #expect(result.header("x-amz-date") == vector.timestamp)
        #expect(result.header("x-amz-content-sha256") == payloadHash)
        #expect(result.header("x-amz-security-token") == vector.expected.securityToken)
        if let documented = vector.documentedSignature {
            #expect(result.signature == documented)
        }
        // The URL query sent on the wire uses the same encoding the SDK serialises.
        let wireQuery = vector.url.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        #expect(PercentEncoding.queryString(request.query) == wireQuery)
    }

    @Test("presigned URLs match botocore (and the AWS documentation)", arguments: Vectors.awsPresign?.cases ?? [])
    func presignedURL(_ vector: AWSPresignCase) throws {
        let file = try #require(Vectors.awsPresign)
        let credentials = try file.signingCredentials(vector.credentials)
        let request = SigningRequest(method: vector.method, host: vector.host, path: vector.path,
                                     query: Vectors.parameters(vector.query), headers: Vectors.headers(vector.headers))
        let signer = AWSSigV4Signer(credentials: credentials, region: vector.region)
        let result = try signer.presign(request, expires: vector.expires, date: try Vectors.date(vector.timestamp))
        #expect(result.canonicalRequest == vector.expected.canonicalRequest)
        #expect(result.stringToSign == vector.expected.stringToSign)
        #expect(result.signature == vector.expected.signature)
        #expect("\(vector.scheme)://\(vector.host)\(PercentEncoding.encodePath(vector.path))?\(result.queryString)" == vector.expected.url)
        if let documented = vector.documentedSignature {
            #expect(result.signature == documented)
        }
    }

    @Test("presign rejects expiries outside 1 s … 7 days", arguments: [0, -5, 604_801, Int.max])
    func presignExpiryBounds(_ expires: Int) {
        let signer = AWSSigV4Signer(credentials: SigningCredentials(accessKeyID: "AK", secretAccessKey: "SK"), region: "us-east-1")
        let request = SigningRequest(method: "GET", host: "b.s3.amazonaws.com", path: "/k")
        #expect(throws: SigningError.self) { try signer.presign(request, expires: expires, date: Date(timeIntervalSince1970: 0)) }
    }

    @Test("blacklisted headers are not signed and duplicate header names are joined")
    func headerSelection() {
        let signer = AWSSigV4Signer(credentials: SigningCredentials(accessKeyID: "AK", secretAccessKey: "SK"), region: "us-east-1")
        let request = SigningRequest(method: "GET", host: "b.s3.amazonaws.com", path: "/k", headers: [
            HTTPHeader("User-Agent", "CcinnBucket/1.0"), HTTPHeader("Expect", "100-continue"),
            HTTPHeader("X-Amz-Meta-A", "one"), HTTPHeader("x-amz-meta-a", "two"),
        ])
        let result = signer.sign(request, payloadHash: PayloadHash.empty, date: Date(timeIntervalSince1970: 0))
        #expect(!result.canonicalRequest.contains("user-agent"))
        #expect(!result.canonicalRequest.contains("expect"))
        #expect(result.canonicalRequest.contains("x-amz-meta-a:one,two\n"))
        #expect(result.header("Authorization")?.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-meta-a,") == true)
    }

    @Test("empty payload hash constant")
    func emptyPayloadHash() {
        #expect(PayloadHash.empty == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(PayloadHash.sha256Hex(Data()) == PayloadHash.empty)
    }
}
