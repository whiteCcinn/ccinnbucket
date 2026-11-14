import Foundation
import StorageSigning

/// Scheme, host and optional port of a service endpoint.
public struct StorageEndpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    public var scheme: String
    public var host: String
    public var port: Int?

    public init(scheme: String = "https", host: String, port: Int? = nil) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    /// Parses `https://host[:port]`, `host[:port]` (HTTPS assumed) or `http://…`. Paths are ignored.
    public init?(string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        if let port = components.port, !(1...65_535).contains(port) { return nil }
        guard Self.isValidHost(host) else { return nil }
        self.init(scheme: scheme, host: host, port: components.port)
    }

    /// Host names, IPv4 and bracketed IPv6 literals only (no spaces, no userinfo, no path tricks).
    static func isValidHost(_ host: String) -> Bool {
        guard host.count <= 253 else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { return host.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_") }
    }

    var isDefaultPort: Bool {
        guard let port else { return true }
        return (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    /// Value of the `Host` header for `host` on this endpoint's scheme/port.
    func hostHeader(_ host: String) -> String { isDefaultPort ? host : "\(host):\(port ?? 0)" }

    public var description: String { "\(scheme)://\(hostHeader(host))" }
}

public enum AddressingStyle: String, Codable, Sendable, Hashable, CaseIterable {
    /// `https://bucket.endpoint/key`
    case virtualHosted
    /// `https://endpoint/bucket/key`
    case path
}

public enum OSSSignatureVersion: String, Codable, Sendable, Hashable, CaseIterable {
    case v4
    case v1
}

public enum OSSEndpointKind: String, Codable, Sendable, Hashable, CaseIterable {
    case `public`
    case `internal`
    case accelerate
}

/// Everything needed to talk to one account (credentials are passed separately).
public struct StorageConfiguration: Sendable, Hashable {
    public var provider: StorageProvider
    /// Explicit endpoint. `nil` derives the endpoint from the region (AWS S3 or OSS public/internal/accelerate).
    public var endpoint: StorageEndpoint?
    /// S3: signing region (`us-east-1` for most S3-compatible services). OSS: region id such as `cn-hangzhou`.
    public var region: String
    public var addressing: AddressingStyle
    public var ossEndpointKind: OSSEndpointKind
    /// OSS custom domain (CNAME) bound to this bucket: requests go to `endpoint` without a bucket prefix.
    public var customDomainBucket: String?
    public var ossSignatureVersion: OSSSignatureVersion
    public var listAPIVersion: ListAPIVersion
    /// Idle timeout per request.
    public var requestTimeout: TimeInterval

    public init(provider: StorageProvider, endpoint: StorageEndpoint? = nil, region: String = "us-east-1",
                addressing: AddressingStyle = .virtualHosted, ossEndpointKind: OSSEndpointKind = .public,
                customDomainBucket: String? = nil, ossSignatureVersion: OSSSignatureVersion = .v4,
                listAPIVersion: ListAPIVersion = .automatic, requestTimeout: TimeInterval = 60) {
        self.provider = provider
        self.endpoint = endpoint
        self.region = region.trimmingCharacters(in: .whitespaces)
        self.addressing = addressing
        self.ossEndpointKind = ossEndpointKind
        self.customDomainBucket = customDomainBucket
        self.ossSignatureVersion = ossSignatureVersion
        self.listAPIVersion = listAPIVersion
        self.requestTimeout = requestTimeout
    }
}

/// Where a bucket lives, learned from listings, headers or error hints.
public struct BucketLocation: Sendable, Hashable {
    /// Signing region (`eu-west-1`, `cn-shanghai`).
    public var region: String
    /// OSS endpoint host for the bucket's region (e.g. `oss-cn-shanghai.aliyuncs.com`).
    public var endpointHost: String?

    public init(region: String, endpointHost: String? = nil) {
        self.region = region
        self.endpointHost = endpointHost
    }
}

/// The concrete URL pieces and signing scope for one request.
struct ResolvedTarget: Sendable, Hashable {
    var scheme: String
    var host: String
    var port: Int?
    /// Decoded URL path.
    var path: String
    var signingRegion: String

    var hostHeader: String {
        let isDefault = port == nil || (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port ?? 0)"
    }

    func url(encodedQuery: String) -> URL? {
        var text = "\(scheme)://\(hostHeader)\(PercentEncoding.encodePath(path))"
        if !encodedQuery.isEmpty { text += "?" + encodedQuery }
        return URL(string: text)
    }
}

public enum BucketNaming {
    /// Whether the bucket can be used as a DNS label in virtual-hosted URLs.
    public static func isVirtualHostCompatible(_ bucket: String, scheme: String) -> Bool {
        guard (3...63).contains(bucket.count), !bucket.contains(".."), !isIPv4Address(bucket) else { return false }
        if scheme == "https", bucket.contains(".") { return false } // wildcard certificates do not cover dots
        guard let first = bucket.first, let last = bucket.last, first.isLowercaseLetterOrDigit, last.isLowercaseLetterOrDigit else { return false }
        return bucket.allSatisfy { $0.isLowercaseLetterOrDigit || $0 == "-" || $0 == "." }
    }

    /// Provider rules for new bucket names. Returns human-readable violations (empty when valid).
    public static func violations(_ name: String, provider: StorageProvider) -> [String] {
        var problems: [String] = []
        if !(3...63).contains(name.count) { problems.append("Use 3 to 63 characters.") }
        let allowsDots = provider == .s3
        if !name.allSatisfy({ $0.isLowercaseLetterOrDigit || $0 == "-" || (allowsDots && $0 == ".") }) {
            problems.append(allowsDots ? "Use only lowercase letters, digits, hyphens and dots." : "Use only lowercase letters, digits and hyphens.")
        }
        if let first = name.first, !first.isLowercaseLetterOrDigit { problems.append("Start with a lowercase letter or digit.") }
        if let last = name.last, !last.isLowercaseLetterOrDigit { problems.append("End with a lowercase letter or digit.") }
        if name.contains("..") || name.contains(".-") || name.contains("-.") { problems.append("Do not put dots next to dots or hyphens.") }
        if isIPv4Address(name) { problems.append("Do not use an IP address as a name.") }
        if provider == .s3, name.hasPrefix("xn--") || name.hasPrefix("sthree-") || name.hasSuffix("-s3alias") || name.hasSuffix("--ol-s3") {
            problems.append("This prefix or suffix is reserved by Amazon S3.")
        }
        return problems
    }

    static func isIPv4Address(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && (Int(part) ?? 999) <= 255
        }
    }
}

extension Character {
    var isLowercaseLetterOrDigit: Bool { isASCII && (isLowercase || isNumber) }
}
