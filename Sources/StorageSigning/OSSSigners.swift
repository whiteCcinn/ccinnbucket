import Foundation

/// Alibaba Cloud OSS Signature Version 4 (`OSS4-HMAC-SHA256`).
///
/// Canonical request: `METHOD\n/<bucket>/<key> (encoded, "/" kept)\ncanonical query\ncanonical headers\n
/// additional headers\nUNSIGNED-PAYLOAD`. Signed headers are every `x-oss-*` header, `content-type`,
/// `content-md5` and the explicitly listed additional headers; values are used verbatim.
public struct OSSV4Signer: Sendable {
    public static let algorithm = "OSS4-HMAC-SHA256"
    public static let maximumExpiry = 604_800

    public let credentials: SigningCredentials
    /// Region id without the `oss-` prefix, e.g. `cn-hangzhou`.
    public let region: String
    public let product: String

    public init(credentials: SigningCredentials, region: String, product: String = "oss") {
        self.credentials = credentials
        self.region = region
        self.product = product
    }

    public func sign(_ request: SigningRequest, date: Date, additionalHeaders: Set<String> = []) -> SignatureResult {
        let timestamp = SigningTime.amzDate(date)
        var added = [HTTPHeader("x-oss-date", timestamp), HTTPHeader("Date", SigningTime.httpDate(date))]
        if let token = credentials.sessionToken { added.append(HTTPHeader("x-oss-security-token", token)) }
        added.append(HTTPHeader("x-oss-content-sha256", PayloadHash.unsigned))

        let replaced: Set<String> = ["x-oss-date", "date", "x-oss-security-token", "x-oss-content-sha256", "authorization"]
        let headers = request.headers.filter { !replaced.contains($0.name.lowercased()) } + added
        let additional = Self.effectiveAdditionalHeaders(additionalHeaders, in: headers)

        let canonicalQuery = PercentEncoding.sortedEncodedPairs(request.query)
            .map { $0.value.isEmpty ? $0.name : "\($0.name)=\($0.value)" }
            .joined(separator: "&")
        let canonicalRequest = [
            request.method,
            Self.canonicalURI(request),
            canonicalQuery,
            Self.canonicalHeaders(headers, additional: additional),
            additional.joined(separator: ";"),
            PayloadHash.unsigned,
        ].joined(separator: "\n")
        let scope = self.scope(date)
        let stringToSign = [Self.algorithm, timestamp, scope, Hashing.sha256Hex(canonicalRequest)].joined(separator: "\n")
        let signature = signatureHex(stringToSign, date: date)
        var authorization = "\(Self.algorithm) Credential=\(credentials.accessKeyID)/\(scope)"
        if !additional.isEmpty { authorization += ",AdditionalHeaders=\(additional.joined(separator: ";"))" }
        authorization += ",Signature=\(signature)"
        return SignatureResult(headers: added + [HTTPHeader("Authorization", authorization)], canonicalRequest: canonicalRequest,
                               stringToSign: stringToSign, signature: signature)
    }

    public func presign(_ request: SigningRequest, expires: Int, date: Date, additionalHeaders: Set<String> = []) throws -> PresignResult {
        guard (1...Self.maximumExpiry).contains(expires) else {
            throw SigningError.invalidExpiry(seconds: expires, maximum: Self.maximumExpiry)
        }
        let timestamp = SigningTime.amzDate(date)
        let scope = self.scope(date)
        let additional = Self.effectiveAdditionalHeaders(additionalHeaders, in: request.headers)
        let reserved: Set<String> = ["x-oss-signature-version", "x-oss-date", "x-oss-expires", "x-oss-credential",
                                     "x-oss-signature", "x-oss-security-token", "x-oss-additional-headers"]
        var parameters = request.query.filter { !reserved.contains($0.name.lowercased()) }
        parameters.append(QueryParameter("x-oss-signature-version", Self.algorithm))
        parameters.append(QueryParameter("x-oss-date", timestamp))
        parameters.append(QueryParameter("x-oss-expires", String(expires)))
        parameters.append(QueryParameter("x-oss-credential", "\(credentials.accessKeyID)/\(scope)"))
        if let token = credentials.sessionToken { parameters.append(QueryParameter("x-oss-security-token", token)) }
        if !additional.isEmpty { parameters.append(QueryParameter("x-oss-additional-headers", additional.joined(separator: ";"))) }

        let canonicalQuery = PercentEncoding.sortedEncodedPairs(parameters)
            .map { $0.value.isEmpty ? $0.name : "\($0.name)=\($0.value)" }
            .joined(separator: "&")
        let canonicalRequest = [
            request.method,
            Self.canonicalURI(request),
            canonicalQuery,
            Self.canonicalHeaders(request.headers, additional: additional),
            additional.joined(separator: ";"),
            PayloadHash.unsigned,
        ].joined(separator: "\n")
        let stringToSign = [Self.algorithm, timestamp, scope, Hashing.sha256Hex(canonicalRequest)].joined(separator: "\n")
        let signature = signatureHex(stringToSign, date: date)
        let query = parameters.map { parameter in
            let name = PercentEncoding.encodeQueryComponent(parameter.name)
            return parameter.value.isEmpty ? name : "\(name)=\(PercentEncoding.encodeQueryComponent(parameter.value))"
        }.joined(separator: "&") + "&x-oss-signature=" + signature
        return PresignResult(queryString: query, canonicalRequest: canonicalRequest, stringToSign: stringToSign, signature: signature)
    }

    func scope(_ date: Date) -> String { "\(SigningTime.dateStamp(date))/\(region)/\(product)/aliyun_v4_request" }

    func signatureHex(_ stringToSign: String, date: Date) -> String {
        let dateKey = Hashing.hmacSHA256(key: Data("aliyun_v4\(credentials.secretAccessKey)".utf8), SigningTime.dateStamp(date))
        let regionKey = Hashing.hmacSHA256(key: dateKey, region)
        let productKey = Hashing.hmacSHA256(key: regionKey, product)
        let signingKey = Hashing.hmacSHA256(key: productKey, "aliyun_v4_request")
        return Hashing.hex(Hashing.hmacSHA256(key: signingKey, stringToSign))
    }

    /// `/<bucket>/<key>` (or `/<bucket>/`, or `/`), percent-encoded with `/` kept.
    static func canonicalURI(_ request: SigningRequest) -> String {
        var uri = "/"
        if let bucket = request.bucket, !bucket.isEmpty { uri += bucket + "/" }
        if let key = request.key { uri += key }
        return PercentEncoding.encodePath(uri)
    }

    static func isDefaultSigned(_ lowercasedName: String) -> Bool {
        lowercasedName.hasPrefix("x-oss-") || lowercasedName == "content-type" || lowercasedName == "content-md5"
    }

    /// Additional headers that are present with a non-empty value and not signed by default, sorted.
    static func effectiveAdditionalHeaders(_ requested: Set<String>, in headers: [HTTPHeader]) -> [String] {
        let present = Dictionary(headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        return Set(requested.map { $0.lowercased() })
            .filter { !isDefaultSigned($0) && !(present[$0] ?? "").isEmpty }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func canonicalHeaders(_ headers: [HTTPHeader], additional: [String]) -> String {
        let extra = Set(additional)
        var selected: [String: String] = [:]
        for header in headers {
            let name = header.name.lowercased()
            if isDefaultSigned(name) || extra.contains(name) { selected[name] = header.value }
        }
        return selected.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { "\($0):\(selected[$0, default: ""])\n" }
            .joined()
    }
}

/// Legacy Alibaba Cloud OSS signature (HMAC-SHA1), kept for older deployments and gateways.
///
/// StringToSign: `METHOD\nContent-MD5\nContent-Type\nDate\n` + canonical `x-oss-` headers + canonical resource,
/// where the resource is `/<bucket>/<key>` (decoded) plus the signed sub-resources only.
public struct OSSV1Signer: Sendable {
    /// Query parameters that are part of the V1 canonical resource (server-side list, as used by oss2).
    public static let signedSubresources: Set<String> = [
        "response-content-type", "response-content-language", "response-cache-control", "logging", "response-content-encoding",
        "acl", "uploadId", "uploads", "partNumber", "group", "link", "delete", "website", "location", "objectInfo", "objectMeta",
        "response-expires", "response-content-disposition", "cors", "lifecycle", "restore", "qos", "referer", "stat", "bucketInfo",
        "append", "position", "security-token", "live", "comp", "status", "vod", "startTime", "endTime", "x-oss-process",
        "symlink", "callback", "callback-var", "tagging", "encryption", "versions", "versioning", "versionId", "policy",
        "requestPayment", "x-oss-traffic-limit", "qosInfo", "asyncFetch", "x-oss-request-payer", "sequential", "inventory",
        "inventoryId", "continuation-token", "worm", "wormId", "wormExtend", "replication", "replicationLocation",
        "replicationProgress", "transferAcceleration", "cname", "metaQuery", "x-oss-ac-source-ip", "x-oss-ac-subnet-mask",
        "x-oss-ac-vpc-id", "x-oss-ac-forward-allow", "resourceGroup", "style", "styleName", "x-oss-async-process", "regionList",
        "x-oss-write-get-object-response", "bucketArchiveDirectRead", "httpsConfig", "redundancyTransition",
        "x-oss-target-redundancy-type", "x-oss-redundancy-transition-taskid", "accessPoint", "accessPointPolicy",
        "publicAccessBlock", "x-oss-access-point-name", "requesterQosInfo", "qosRequester", "resourcePoolInfo", "resourcePool",
        "resourcePoolBuckets",
    ]

    public let credentials: SigningCredentials

    public init(credentials: SigningCredentials) {
        self.credentials = credentials
    }

    public func sign(_ request: SigningRequest, date: Date) -> SignatureResult {
        var added = [HTTPHeader("Date", SigningTime.httpDate(date))]
        if let token = credentials.sessionToken { added.append(HTTPHeader("x-oss-security-token", token)) }
        let replaced: Set<String> = ["date", "x-oss-security-token", "authorization"]
        let headers = request.headers.filter { !replaced.contains($0.name.lowercased()) } + added
        let dateValue = Self.value("x-oss-date", in: headers) ?? Self.value("date", in: headers) ?? ""
        let stringToSign = self.stringToSign(request, headers: headers, date: dateValue, query: request.query)
        let signature = Hashing.hmacSHA1Base64(key: credentials.secretAccessKey, stringToSign)
        return SignatureResult(headers: added + [HTTPHeader("Authorization", "OSS \(credentials.accessKeyID):\(signature)")],
                               canonicalRequest: stringToSign, stringToSign: stringToSign, signature: signature)
    }

    /// V1 presigned URL query valid until `expiresAt` (Unix seconds).
    public func presign(_ request: SigningRequest, expiresAt: Int) -> PresignResult {
        let reserved: Set<String> = ["ossaccesskeyid", "expires", "signature", "security-token"]
        var parameters = request.query.filter { !reserved.contains($0.name.lowercased()) }
        if let token = credentials.sessionToken { parameters.append(QueryParameter("security-token", token)) }
        let stringToSign = self.stringToSign(request, headers: request.headers, date: String(expiresAt), query: parameters)
        let signature = Hashing.hmacSHA1Base64(key: credentials.secretAccessKey, stringToSign)
        parameters.append(QueryParameter("OSSAccessKeyId", credentials.accessKeyID))
        parameters.append(QueryParameter("Expires", String(expiresAt)))
        parameters.append(QueryParameter("Signature", signature))
        let query = parameters.map { parameter in
            let name = PercentEncoding.encodeQueryComponent(parameter.name)
            return parameter.value.isEmpty ? name : "\(name)=\(PercentEncoding.encodeQueryComponent(parameter.value))"
        }.joined(separator: "&")
        return PresignResult(queryString: query, canonicalRequest: stringToSign, stringToSign: stringToSign, signature: signature)
    }

    /// `/<bucket>/<key>?<signed sub-resources>` with decoded values.
    public func canonicalResource(_ request: SigningRequest) -> String {
        canonicalResource(request, query: request.query)
    }

    func canonicalResource(_ request: SigningRequest, query: [QueryParameter]) -> String {
        var resource = "/"
        if let bucket = request.bucket, !bucket.isEmpty { resource += bucket + "/" + (request.key ?? "") }
        let subresources = query.filter { Self.signedSubresources.contains($0.name) }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) }
                return lhs.value.utf8.lexicographicallyPrecedes(rhs.value.utf8)
            }
            .map { $0.value.isEmpty ? $0.name : "\($0.name)=\($0.value)" }
        if !subresources.isEmpty { resource += "?" + subresources.joined(separator: "&") }
        return resource
    }

    func stringToSign(_ request: SigningRequest, headers: [HTTPHeader], date: String, query: [QueryParameter]) -> String {
        var ossHeaders: [String: String] = [:]
        for header in headers where header.name.lowercased().hasPrefix("x-oss-") {
            ossHeaders[header.name.lowercased()] = header.value
        }
        let canonicalHeaders = ossHeaders.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            .map { "\($0):\(ossHeaders[$0, default: ""])\n" }
            .joined()
        return [
            request.method,
            Self.value("content-md5", in: headers) ?? "",
            Self.value("content-type", in: headers) ?? "",
            date,
            canonicalHeaders + canonicalResource(request, query: query),
        ].joined(separator: "\n")
    }

    static func value(_ name: String, in headers: [HTTPHeader]) -> String? {
        headers.last { $0.name.lowercased() == name }?.value
    }

    public static func httpDate(_ date: Date) -> String { SigningTime.httpDate(date) }
    public static func parseHTTPDate(_ text: String) -> Date? { SigningTime.parseHTTPDate(text) }
}
