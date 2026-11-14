import Foundation
import StorageSigning

/// Everything that differs between Amazon S3 (and S3-compatible services) and Alibaba Cloud OSS.
/// `ObjectStorageClient` implements every operation once and asks the dialect for the differences.
protocol ProviderDialect: Sendable {
    var provider: StorageProvider { get }
    /// `x-amz-` or `x-oss-`.
    var headerPrefix: String { get }
    var requestIDHeaders: [String] { get }
    /// S3 URL-encodes listing keys with `+` for spaces (form encoding); OSS uses plain percent-encoding.
    var listingPlusAsSpace: Bool { get }
    /// Largest object a single CopyObject may copy.
    var maxSingleCopySize: Int64 { get }
    var storageClasses: [String] { get }
    var defaultStorageClass: String { get }
    /// Whether every non-empty body should carry `Content-MD5` (OSS signs `UNSIGNED-PAYLOAD`).
    var sendsContentMD5ForBodies: Bool { get }

    func resolve(bucket: String?, key: String?, location: BucketLocation?) throws -> ResolvedTarget
    func sign(_ request: SigningRequest, payloadHash: String, region: String, date: Date, credentials: SigningCredentials) -> [HTTPHeader]
    func presign(_ request: SigningRequest, region: String, expires: Int, date: Date, credentials: SigningCredentials) throws -> String
    /// Location of a bucket reported by ListBuckets.
    func location(of bucket: BucketInfo) -> BucketLocation?
    /// A corrected location suggested by a failed response, if any.
    func relocationHint(error: StorageError, response: HTTPResponse, attempted: BucketLocation) -> BucketLocation?
    /// Location learned from a successful response (e.g. `x-amz-bucket-region`).
    func observedLocation(response: HTTPResponse) -> BucketLocation?
    func parseLocationConstraint(_ root: XElement) -> BucketLocation?
    func createBucketBody(region: String?) -> Data?
    /// The location used when nothing is cached for a bucket.
    var defaultLocation: BucketLocation { get }
    func parseACL(_ root: XElement) -> [SettingItem]
}

extension ProviderDialect {
    var metadataPrefix: String { headerPrefix + "meta-" }
    var copySourceHeader: String { headerPrefix + "copy-source" }
    var copySourceRangeHeader: String { headerPrefix + "copy-source-range" }
    var metadataDirectiveHeader: String { headerPrefix + "metadata-directive" }
    var taggingDirectiveHeader: String { headerPrefix + "tagging-directive" }
    var storageClassHeader: String { headerPrefix + "storage-class" }
    var taggingHeader: String { headerPrefix + "tagging" }
    var versionIDHeader: String { headerPrefix + "version-id" }
    var deleteMarkerHeader: String { headerPrefix + "delete-marker" }
    var sseHeader: String { headerPrefix + "server-side-encryption" }
}

// MARK: - Amazon S3 and S3-compatible

struct S3Dialect: ProviderDialect {
    let configuration: StorageConfiguration

    var provider: StorageProvider { .s3 }
    var headerPrefix: String { "x-amz-" }
    var requestIDHeaders: [String] { ["x-amz-request-id"] }
    var listingPlusAsSpace: Bool { true }
    var maxSingleCopySize: Int64 { 5 << 30 }
    var storageClasses: [String] {
        ["STANDARD", "INTELLIGENT_TIERING", "STANDARD_IA", "ONEZONE_IA", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE", "REDUCED_REDUNDANCY"]
    }
    var defaultStorageClass: String { "STANDARD" }
    var sendsContentMD5ForBodies: Bool { false }

    /// AWS-managed endpoints are routed per bucket region; anything else is a fixed custom endpoint.
    var isAWSManaged: Bool {
        guard let endpoint = configuration.endpoint else { return true }
        return endpoint.host.hasSuffix(".amazonaws.com") || endpoint.host.hasSuffix(".amazonaws.com.cn")
    }

    var defaultLocation: BucketLocation {
        if let endpoint = configuration.endpoint, isAWSManaged, let region = Self.region(fromAWSHost: endpoint.host) {
            return BucketLocation(region: region)
        }
        return BucketLocation(region: configuration.region.isEmpty ? "us-east-1" : configuration.region)
    }

    static func awsHost(region: String) -> String {
        region.hasPrefix("cn-") ? "s3.\(region).amazonaws.com.cn" : "s3.\(region).amazonaws.com"
    }

    /// `s3.eu-west-1.amazonaws.com`, `s3-eu-west-1.amazonaws.com`, `bucket.s3.dualstack.eu-west-1.amazonaws.com` → `eu-west-1`.
    static func region(fromAWSHost host: String) -> String? {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard let s3Index = labels.firstIndex(where: { $0 == "s3" || $0.hasPrefix("s3-") }) else { return nil }
        let label = labels[s3Index]
        if label.hasPrefix("s3-"), label != "s3-accelerate", label != "s3-external-1" { return String(label.dropFirst(3)) }
        var next = s3Index + 1
        if labels.indices.contains(next), labels[next] == "dualstack" { next += 1 }
        guard labels.indices.contains(next), labels[next] != "amazonaws" else { return label == "s3" ? "us-east-1" : nil }
        return labels[next]
    }

    func resolve(bucket: String?, key: String?, location: BucketLocation?) throws -> ResolvedTarget {
        let region = location?.region ?? defaultLocation.region
        let scheme = configuration.endpoint?.scheme ?? "https"
        let port = configuration.endpoint?.port
        let endpointHost: String
        if let endpoint = configuration.endpoint, !isAWSManaged {
            endpointHost = endpoint.host
        } else {
            endpointHost = Self.awsHost(region: region)
        }
        guard let bucket else {
            return ResolvedTarget(scheme: scheme, host: endpointHost, port: port, path: "/", signingRegion: region)
        }
        let hostIsAddress = BucketNaming.isIPv4Address(endpointHost) || endpointHost.hasPrefix("[") || endpointHost == "localhost"
        let virtual = configuration.addressing == .virtualHosted && !hostIsAddress
            && BucketNaming.isVirtualHostCompatible(bucket, scheme: scheme)
        if virtual {
            return ResolvedTarget(scheme: scheme, host: "\(bucket).\(endpointHost)", port: port, path: "/" + (key ?? ""), signingRegion: region)
        }
        let path = key.map { "/\(bucket)/\($0)" } ?? "/\(bucket)"
        return ResolvedTarget(scheme: scheme, host: endpointHost, port: port, path: path, signingRegion: region)
    }

    func sign(_ request: SigningRequest, payloadHash: String, region: String, date: Date, credentials: SigningCredentials) -> [HTTPHeader] {
        AWSSigV4Signer(credentials: credentials, region: region).sign(request, payloadHash: payloadHash, date: date).headers
    }

    func presign(_ request: SigningRequest, region: String, expires: Int, date: Date, credentials: SigningCredentials) throws -> String {
        try AWSSigV4Signer(credentials: credentials, region: region).presign(request, expires: expires, date: date).queryString
    }

    func location(of bucket: BucketInfo) -> BucketLocation? {
        guard isAWSManaged, let region = bucket.region, !region.isEmpty else { return nil }
        return BucketLocation(region: region)
    }

    func relocationHint(error: StorageError, response: HTTPResponse, attempted: BucketLocation) -> BucketLocation? {
        guard [301, 307, 400, 403].contains(response.statusCode) else { return nil }
        var candidate = response.header("x-amz-bucket-region") ?? error.details["Region"]
        if candidate == nil, let endpoint = error.details["Endpoint"] { candidate = Self.region(fromAWSHost: endpoint) }
        if candidate == nil, response.statusCode == 307, let location = response.header("location"),
           let host = URL(string: location)?.host { candidate = Self.region(fromAWSHost: host) }
        guard let region = candidate?.trimmingCharacters(in: .whitespaces), !region.isEmpty, region != attempted.region,
              region.count <= 64, region.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return BucketLocation(region: region)
    }

    func observedLocation(response: HTTPResponse) -> BucketLocation? {
        guard isAWSManaged, let region = response.header("x-amz-bucket-region"), !region.isEmpty else { return nil }
        return BucketLocation(region: region)
    }

    func parseLocationConstraint(_ root: XElement) -> BucketLocation? {
        let text = root.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "": return BucketLocation(region: "us-east-1")
        case "EU": return BucketLocation(region: "eu-west-1")
        default: return BucketLocation(region: text)
        }
    }

    func createBucketBody(region: String?) -> Data? {
        guard let region, !region.isEmpty, region != "us-east-1" else { return nil }
        var writer = XMLWriter()
        writer.open("CreateBucketConfiguration", attributes: ["xmlns": "http://s3.amazonaws.com/doc/2006-03-01/"])
        writer.element("LocationConstraint", region)
        writer.close("CreateBucketConfiguration")
        return writer.data
    }

    func parseACL(_ root: XElement) -> [SettingItem] {
        var items: [SettingItem] = []
        if let owner = root.child("Owner") {
            items.append(SettingItem(title: "Owner", fields: [
                SettingField("Name", owner.childText("DisplayName") ?? "—"), SettingField("ID", owner.childText("ID") ?? "—"),
            ]))
        }
        for grant in root.child("AccessControlList")?.children("Grant") ?? [] {
            let grantee = grant.child("Grantee")
            let who: String
            if let uri = grantee?.childText("URI") {
                who = switch uri {
                case let value where value.hasSuffix("/AllUsers"): "Everyone (public)"
                case let value where value.hasSuffix("/AuthenticatedUsers"): "Any authenticated AWS user"
                case let value where value.hasSuffix("/LogDelivery"): "Log delivery group"
                default: uri
                }
            } else {
                who = grantee?.childText("DisplayName") ?? grantee?.childText("ID") ?? grantee?.childText("EmailAddress") ?? "Unknown grantee"
            }
            items.append(SettingItem(title: who, fields: [SettingField("Permission", grant.childText("Permission") ?? "—")]))
        }
        return items
    }
}

// MARK: - Alibaba Cloud OSS

struct OSSDialect: ProviderDialect {
    let configuration: StorageConfiguration

    var provider: StorageProvider { .oss }
    var headerPrefix: String { "x-oss-" }
    var requestIDHeaders: [String] { ["x-oss-request-id"] }
    var listingPlusAsSpace: Bool { false }
    var maxSingleCopySize: Int64 { 1 << 30 }
    var storageClasses: [String] { ["Standard", "IA", "Archive", "ColdArchive", "DeepColdArchive"] }
    var defaultStorageClass: String { "Standard" }
    var sendsContentMD5ForBodies: Bool { true }

    var defaultLocation: BucketLocation {
        let region = configuration.region.isEmpty ? (configuration.endpoint.flatMap { Self.region(fromHost: $0.host) } ?? "cn-hangzhou")
            : Self.normalizedRegion(configuration.region)
        return BucketLocation(region: region, endpointHost: configuration.endpoint?.host ?? Self.endpointHost(region: region, kind: configuration.ossEndpointKind))
    }

    /// `oss-cn-hangzhou` / `cn-hangzhou` → `cn-hangzhou`.
    static func normalizedRegion(_ region: String) -> String {
        let trimmed = region.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("oss-") ? String(trimmed.dropFirst(4)) : trimmed
    }

    static func endpointHost(region: String, kind: OSSEndpointKind) -> String {
        switch kind {
        case .public: "oss-\(region).aliyuncs.com"
        case .internal: "oss-\(region)-internal.aliyuncs.com"
        case .accelerate: "oss-accelerate.aliyuncs.com"
        }
    }

    /// `oss-cn-shanghai.aliyuncs.com`, `oss-cn-shanghai-internal.aliyuncs.com`, `bucket.oss-…` → `cn-shanghai`.
    static func region(fromHost host: String) -> String? {
        for label in host.lowercased().split(separator: ".") where label.hasPrefix("oss-") {
            var region = String(label.dropFirst(4))
            if region.hasSuffix("-internal") { region = String(region.dropLast(9)) }
            if region == "accelerate" || region == "accelerate-overseas" || region.isEmpty { return nil }
            return region
        }
        return nil
    }

    static func isAliyunRegionalHost(_ host: String) -> Bool {
        host.hasSuffix(".aliyuncs.com") && region(fromHost: host) != nil
    }

    func resolve(bucket: String?, key: String?, location: BucketLocation?) throws -> ResolvedTarget {
        let scheme = configuration.endpoint?.scheme ?? "https"
        let port = configuration.endpoint?.port
        let fallback = defaultLocation
        let region = location?.region ?? fallback.region

        if let bucket, let custom = configuration.customDomainBucket, custom == bucket, let endpoint = configuration.endpoint {
            return ResolvedTarget(scheme: scheme, host: endpoint.host, port: port, path: "/" + (key ?? ""), signingRegion: region)
        }

        var endpointHost = fallback.endpointHost ?? Self.endpointHost(region: region, kind: configuration.ossEndpointKind)
        let configuredIsRegional = configuration.endpoint.map { Self.isAliyunRegionalHost($0.host) } ?? true
        if configuredIsRegional, let location, location.region != fallback.region {
            endpointHost = Self.endpointHost(region: location.region, kind: configuration.ossEndpointKind == .accelerate ? .public : configuration.ossEndpointKind)
            if configuration.endpoint?.host.contains("-internal.") == true { endpointHost = Self.endpointHost(region: location.region, kind: .internal) }
        }
        guard let bucket else {
            return ResolvedTarget(scheme: scheme, host: endpointHost, port: port, path: "/", signingRegion: region)
        }
        if configuration.addressing == .path || BucketNaming.isIPv4Address(endpointHost) || endpointHost == "localhost" {
            return ResolvedTarget(scheme: scheme, host: endpointHost, port: port, path: "/\(bucket)/" + (key ?? ""), signingRegion: region)
        }
        return ResolvedTarget(scheme: scheme, host: "\(bucket).\(endpointHost)", port: port, path: "/" + (key ?? ""), signingRegion: region)
    }

    func sign(_ request: SigningRequest, payloadHash: String, region: String, date: Date, credentials: SigningCredentials) -> [HTTPHeader] {
        switch configuration.ossSignatureVersion {
        case .v4: OSSV4Signer(credentials: credentials, region: region).sign(request, date: date).headers
        case .v1: OSSV1Signer(credentials: credentials).sign(request, date: date).headers
        }
    }

    func presign(_ request: SigningRequest, region: String, expires: Int, date: Date, credentials: SigningCredentials) throws -> String {
        switch configuration.ossSignatureVersion {
        case .v4:
            return try OSSV4Signer(credentials: credentials, region: region).presign(request, expires: expires, date: date).queryString
        case .v1:
            guard (1...OSSV4Signer.maximumExpiry).contains(expires) else {
                throw SigningError.invalidExpiry(seconds: expires, maximum: OSSV4Signer.maximumExpiry)
            }
            return OSSV1Signer(credentials: credentials).presign(request, expiresAt: SigningTime.unixSeconds(date) + expires).queryString
        }
    }

    func location(of bucket: BucketInfo) -> BucketLocation? {
        let region = bucket.region.map(Self.normalizedRegion) ?? bucket.extranetEndpoint.flatMap(Self.region(fromHost:))
        guard let region, !region.isEmpty else { return nil }
        let host = configuration.ossEndpointKind == .internal ? bucket.intranetEndpoint : bucket.extranetEndpoint
        return BucketLocation(region: region, endpointHost: host ?? Self.endpointHost(region: region, kind: configuration.ossEndpointKind))
    }

    func relocationHint(error: StorageError, response: HTTPResponse, attempted: BucketLocation) -> BucketLocation? {
        guard let endpoint = error.details["Endpoint"]?.trimmingCharacters(in: .whitespaces).lowercased(), !endpoint.isEmpty,
              StorageEndpoint.isValidHost(endpoint), let region = Self.region(fromHost: endpoint), region != attempted.region else { return nil }
        return BucketLocation(region: region, endpointHost: endpoint)
    }

    func observedLocation(response: HTTPResponse) -> BucketLocation? { nil }

    func parseLocationConstraint(_ root: XElement) -> BucketLocation? {
        let region = Self.normalizedRegion(root.text)
        guard !region.isEmpty else { return nil }
        return BucketLocation(region: region, endpointHost: Self.endpointHost(region: region, kind: configuration.ossEndpointKind))
    }

    func createBucketBody(region: String?) -> Data? {
        var writer = XMLWriter()
        writer.open("CreateBucketConfiguration")
        writer.element("StorageClass", "Standard")
        writer.close("CreateBucketConfiguration")
        return writer.data
    }

    func parseACL(_ root: XElement) -> [SettingItem] {
        var items: [SettingItem] = []
        if let owner = root.child("Owner") {
            items.append(SettingItem(title: "Owner", fields: [
                SettingField("Name", owner.childText("DisplayName") ?? "—"), SettingField("ID", owner.childText("ID") ?? "—"),
            ]))
        }
        if let grant = root.child("AccessControlList")?.childText("Grant") {
            let meaning = switch grant {
            case "private": "Only the owner and authorised users can read or write"
            case "public-read": "Everyone can read; only the owner can write"
            case "public-read-write": "Everyone can read and write"
            default: grant
            }
            items.append(SettingItem(title: "Access", fields: [SettingField("ACL", grant), SettingField("Meaning", meaning)]))
        }
        return items
    }
}
