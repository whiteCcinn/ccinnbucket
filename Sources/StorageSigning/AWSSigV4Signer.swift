import Foundation

/// AWS Signature Version 4 for S3 and S3-compatible services.
///
/// Canonical request (S3 flavour — the path is encoded once and never normalised):
/// `METHOD\nencoded path\ncanonical query\ncanonical headers\n\nsigned headers\npayload hash`.
public struct AWSSigV4Signer: Sendable {
    public static let algorithm = "AWS4-HMAC-SHA256"
    /// SigV4 presigned URLs are valid for at most seven days.
    public static let maximumExpiry = 604_800
    /// Headers that intermediaries may change; never signed (same list as botocore).
    static let unsignedHeaders: Set<String> = ["expect", "transfer-encoding", "user-agent", "x-amzn-trace-id"]

    public let credentials: SigningCredentials
    public let region: String
    public let service: String

    public init(credentials: SigningCredentials, region: String, service: String = "s3") {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    /// Signs with the `Authorization` header. `payloadHash` is the hex SHA-256 of the body or `UNSIGNED-PAYLOAD`.
    public func sign(_ request: SigningRequest, payloadHash: String, date: Date) -> SignatureResult {
        let amzDate = SigningTime.amzDate(date)
        var added = [HTTPHeader("x-amz-date", amzDate), HTTPHeader("x-amz-content-sha256", payloadHash)]
        if let token = credentials.sessionToken { added.append(HTTPHeader("x-amz-security-token", token)) }

        let replaced: Set<String> = ["x-amz-date", "x-amz-content-sha256", "x-amz-security-token", "authorization", "host"]
        var headers = request.headers.filter { !replaced.contains($0.name.lowercased()) }
        headers.append(HTTPHeader("host", request.host))
        headers.append(contentsOf: added)

        let (canonicalHeaders, signedHeaders) = Self.canonicalHeaders(headers)
        let canonicalRequest = [
            request.method,
            PercentEncoding.encodePath(request.path),
            PercentEncoding.canonicalQuery(request.query),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = credentialScope(date)
        let stringToSign = [Self.algorithm, amzDate, scope, Hashing.sha256Hex(canonicalRequest)].joined(separator: "\n")
        let signature = signatureHex(stringToSign, date: date)
        let authorization = "\(Self.algorithm) Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return SignatureResult(headers: added + [HTTPHeader("Authorization", authorization)],
                               canonicalRequest: canonicalRequest, stringToSign: stringToSign, signature: signature)
    }

    /// Presigned URL query (`UNSIGNED-PAYLOAD`). Only `host` and any given headers are signed.
    public func presign(_ request: SigningRequest, expires: Int, date: Date) throws -> PresignResult {
        guard (1...Self.maximumExpiry).contains(expires) else {
            throw SigningError.invalidExpiry(seconds: expires, maximum: Self.maximumExpiry)
        }
        var headers = request.headers.filter { $0.name.lowercased() != "host" }
        headers.append(HTTPHeader("host", request.host))
        let (canonicalHeaders, signedHeaders) = Self.canonicalHeaders(headers)
        let amzDate = SigningTime.amzDate(date)
        let scope = credentialScope(date)

        let reserved: Set<String> = ["x-amz-algorithm", "x-amz-credential", "x-amz-date", "x-amz-expires",
                                     "x-amz-signedheaders", "x-amz-security-token", "x-amz-signature"]
        var parameters = request.query.filter { !reserved.contains($0.name.lowercased()) }
        parameters.append(QueryParameter("X-Amz-Algorithm", Self.algorithm))
        parameters.append(QueryParameter("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"))
        parameters.append(QueryParameter("X-Amz-Date", amzDate))
        parameters.append(QueryParameter("X-Amz-Expires", String(expires)))
        parameters.append(QueryParameter("X-Amz-SignedHeaders", signedHeaders))
        if let token = credentials.sessionToken { parameters.append(QueryParameter("X-Amz-Security-Token", token)) }

        let canonicalRequest = [
            request.method,
            PercentEncoding.encodePath(request.path),
            PercentEncoding.canonicalQuery(parameters),
            canonicalHeaders,
            signedHeaders,
            PayloadHash.unsigned,
        ].joined(separator: "\n")
        let stringToSign = [Self.algorithm, amzDate, scope, Hashing.sha256Hex(canonicalRequest)].joined(separator: "\n")
        let signature = signatureHex(stringToSign, date: date)
        let query = PercentEncoding.queryString(parameters) + "&X-Amz-Signature=" + signature
        return PresignResult(queryString: query, canonicalRequest: canonicalRequest, stringToSign: stringToSign, signature: signature)
    }

    func credentialScope(_ date: Date) -> String {
        "\(SigningTime.dateStamp(date))/\(region)/\(service)/aws4_request"
    }

    func signatureHex(_ stringToSign: String, date: Date) -> String {
        let dateKey = Hashing.hmacSHA256(key: Data("AWS4\(credentials.secretAccessKey)".utf8), SigningTime.dateStamp(date))
        let regionKey = Hashing.hmacSHA256(key: dateKey, region)
        let serviceKey = Hashing.hmacSHA256(key: regionKey, service)
        let signingKey = Hashing.hmacSHA256(key: serviceKey, "aws4_request")
        return Hashing.hex(Hashing.hmacSHA256(key: signingKey, stringToSign))
    }

    /// Lower-cased, sorted, trim-all'd header lines (each followed by `\n`) and the signed-header list.
    static func canonicalHeaders(_ headers: [HTTPHeader]) -> (canonical: String, signed: String) {
        var grouped: [String: [String]] = [:]
        for header in headers {
            let name = header.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !unsignedHeaders.contains(name) else { continue }
            grouped[name, default: []].append(trimAll(header.value))
        }
        let names = grouped.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let canonical = names.map { "\($0):\(grouped[$0, default: []].joined(separator: ","))\n" }.joined()
        return (canonical, names.joined(separator: ";"))
    }

    /// Removes leading/trailing whitespace and collapses internal runs to one space.
    static func trimAll(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
