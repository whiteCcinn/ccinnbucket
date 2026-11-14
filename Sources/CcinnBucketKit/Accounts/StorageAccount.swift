import Foundation
import StorageKit

public enum AccountColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

/// Which service an account talks to. Presets only choose sensible defaults; every field stays editable.
public enum AccountKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case amazonS3
    case minio
    case cloudflareR2
    case cephRGW
    case wasabi
    case tencentCOS
    case otherS3
    case alibabaOSS

    public var id: String { rawValue }

    public var provider: StorageProvider { self == .alibabaOSS ? .oss : .s3 }

    public var displayName: String {
        switch self {
        case .amazonS3: "Amazon S3"
        case .minio: "MinIO"
        case .cloudflareR2: "Cloudflare R2"
        case .cephRGW: "Ceph RGW"
        case .wasabi: "Wasabi"
        case .tencentCOS: "Tencent COS (S3 API)"
        case .otherS3: "Other S3-compatible"
        case .alibabaOSS: "Alibaba Cloud OSS"
        }
    }

    /// Whether the user must type an endpoint (AWS and OSS derive it from the region).
    public var requiresEndpoint: Bool {
        switch self {
        case .amazonS3, .alibabaOSS: false
        default: true
        }
    }

    public var defaultRegion: String {
        switch self {
        case .cloudflareR2: "auto"
        case .tencentCOS: "ap-guangzhou"
        case .alibabaOSS: "cn-hangzhou"
        default: "us-east-1"
        }
    }

    public var defaultAddressing: AddressingStyle {
        switch self {
        case .amazonS3, .wasabi, .tencentCOS, .alibabaOSS: .virtualHosted
        case .minio, .cloudflareR2, .cephRGW, .otherS3: .path
        }
    }

    /// Placeholder shown in the endpoint field.
    public var endpointPlaceholder: String {
        switch self {
        case .amazonS3: "Derived from the region (optional override)"
        case .minio: "http://127.0.0.1:9000"
        case .cloudflareR2: "https://<account-id>.r2.cloudflarestorage.com"
        case .cephRGW: "https://rgw.example.com"
        case .wasabi: "https://s3.us-east-1.wasabisys.com"
        case .tencentCOS: "https://cos.ap-guangzhou.myqcloud.com"
        case .otherS3: "https://s3.example.com"
        case .alibabaOSS: "Derived from the region (or a custom domain)"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .wasabi: "https://s3.us-east-1.wasabisys.com"
        case .tencentCOS: "https://cos.ap-guangzhou.myqcloud.com"
        default: ""
        }
    }

    public var symbolName: String {
        switch self {
        case .amazonS3: "shippingbox"
        case .minio: "externaldrive.connected.to.line.below"
        case .cloudflareR2: "cloud"
        case .cephRGW: "server.rack"
        case .wasabi: "leaf"
        case .tencentCOS: "cloud.fill"
        case .otherS3: "cube.transparent"
        case .alibabaOSS: "globe.asia.australia"
        }
    }

    /// Common regions offered in the region picker (free text is always allowed).
    public var suggestedRegions: [String] {
        switch self {
        case .amazonS3:
            ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1",
             "eu-north-1", "ap-southeast-1", "ap-southeast-2", "ap-southeast-5", "ap-northeast-1", "ap-northeast-2", "ap-south-1",
             "sa-east-1", "me-south-1", "af-south-1", "cn-north-1", "cn-northwest-1"]
        case .alibabaOSS:
            ["cn-hangzhou", "cn-shanghai", "cn-beijing", "cn-shenzhen", "cn-qingdao", "cn-zhangjiakou", "cn-chengdu", "cn-hongkong",
             "ap-southeast-1", "ap-southeast-3", "ap-southeast-5", "ap-northeast-1", "eu-central-1", "eu-west-1", "us-west-1", "us-east-1"]
        case .tencentCOS:
            ["ap-guangzhou", "ap-shanghai", "ap-beijing", "ap-chengdu", "ap-hongkong", "ap-singapore", "na-siliconvalley"]
        case .wasabi:
            ["us-east-1", "us-east-2", "us-west-1", "eu-central-1", "eu-west-1", "ap-northeast-1", "ap-southeast-1"]
        case .cloudflareR2: ["auto"]
        default: ["us-east-1"]
        }
    }
}

/// A saved storage account. Never contains secrets: the secret access key and session token live in a
/// `SecretStore` (the Keychain).
public struct StorageAccount: Codable, Identifiable, Hashable, Sendable {
    public static let defaultPartSizeMiB = 8

    public var id: UUID
    public var name: String
    public var color: AccountColor
    public var isFavorite: Bool
    public var kind: AccountKind
    /// Empty for AWS / OSS region-derived endpoints.
    public var endpoint: String
    public var region: String
    public var addressing: AddressingStyle
    public var ossEndpointKind: OSSEndpointKind
    public var ossSignatureVersion: OSSSignatureVersion
    /// OSS: `endpoint` is a custom domain bound to `customDomainBucket`.
    public var usesCustomDomain: Bool
    public var customDomainBucket: String
    public var listAPIVersion: ListAPIVersion
    public var accessKeyID: String
    public var defaultBucket: String
    /// Refuse every operation that changes data.
    public var isReadOnly: Bool
    public var partSizeMiB: Int
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(id: UUID = UUID(), kind: AccountKind, name: String = "", accessKeyID: String = "", color: AccountColor = .cyan) {
        self.id = id
        self.name = name
        self.color = color
        isFavorite = false
        self.kind = kind
        endpoint = kind.defaultEndpoint
        region = kind.defaultRegion
        addressing = kind.defaultAddressing
        ossEndpointKind = .public
        ossSignatureVersion = .v4
        usesCustomDomain = false
        customDomainBucket = ""
        listAPIVersion = .automatic
        self.accessKeyID = accessKeyID
        defaultBucket = ""
        isReadOnly = false
        partSizeMiB = Self.defaultPartSizeMiB
        createdAt = Date()
        lastConnectedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, color, isFavorite, kind, endpoint, region, addressing, ossEndpointKind, ossSignatureVersion, usesCustomDomain,
             customDomainBucket, listAPIVersion, accessKeyID, defaultBucket, isReadOnly, partSizeMiB, createdAt, lastConnectedAt
    }

    /// Lenient decoding: fields added in later versions fall back to the preset defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(AccountKind.self, forKey: .kind)
        self.init(id: try container.decode(UUID.self, forKey: .id), kind: kind)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = (try? container.decodeIfPresent(AccountColor.self, forKey: .color)) ?? .cyan
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? kind.defaultEndpoint
        region = try container.decodeIfPresent(String.self, forKey: .region) ?? kind.defaultRegion
        addressing = (try? container.decodeIfPresent(AddressingStyle.self, forKey: .addressing)) ?? kind.defaultAddressing
        ossEndpointKind = (try? container.decodeIfPresent(OSSEndpointKind.self, forKey: .ossEndpointKind)) ?? .public
        ossSignatureVersion = (try? container.decodeIfPresent(OSSSignatureVersion.self, forKey: .ossSignatureVersion)) ?? .v4
        usesCustomDomain = try container.decodeIfPresent(Bool.self, forKey: .usesCustomDomain) ?? false
        customDomainBucket = try container.decodeIfPresent(String.self, forKey: .customDomainBucket) ?? ""
        listAPIVersion = (try? container.decodeIfPresent(ListAPIVersion.self, forKey: .listAPIVersion)) ?? .automatic
        accessKeyID = try container.decodeIfPresent(String.self, forKey: .accessKeyID) ?? ""
        defaultBucket = try container.decodeIfPresent(String.self, forKey: .defaultBucket) ?? ""
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
        partSizeMiB = try container.decodeIfPresent(Int.self, forKey: .partSizeMiB) ?? Self.defaultPartSizeMiB
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return kind.requiresEndpoint ? (StorageEndpoint(string: endpoint)?.host ?? kind.displayName) : "\(kind.displayName) · \(region)"
    }

    /// One-line description for lists: endpoint (or region) and access key.
    public var summary: String {
        var parts = [effectiveEndpointDescription]
        if !accessKeyID.isEmpty { parts.append(Self.mask(accessKeyID)) }
        return parts.joined(separator: " · ")
    }

    static func mask(_ key: String) -> String {
        key.count > 8 ? String(key.prefix(4)) + "…" + String(key.suffix(4)) : key
    }

    /// The endpoint requests go to (before per-bucket region routing).
    public var effectiveEndpointDescription: String {
        if let parsed = StorageEndpoint(string: endpoint), !endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            return parsed.description
        }
        switch kind.provider {
        case .s3:
            let region = region.isEmpty ? "us-east-1" : region
            return region.hasPrefix("cn-") ? "https://s3.\(region).amazonaws.com.cn" : "https://s3.\(region).amazonaws.com"
        case .oss:
            let region = region.isEmpty ? "cn-hangzhou" : region
            switch ossEndpointKind {
            case .public: return "https://oss-\(region).aliyuncs.com"
            case .internal: return "https://oss-\(region)-internal.aliyuncs.com"
            case .accelerate: return "https://oss-accelerate.aliyuncs.com"
            }
        }
    }

    /// Problems that prevent connecting, for inline form validation.
    public var validationErrors: [String] {
        var errors: [String] = []
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
        if kind.requiresEndpoint, trimmedEndpoint.isEmpty {
            errors.append("Enter the endpoint URL")
        } else if !trimmedEndpoint.isEmpty, StorageEndpoint(string: trimmedEndpoint) == nil {
            errors.append("The endpoint is not a valid http(s) URL")
        }
        if region.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the region") }
        if accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the access key ID") }
        if kind.provider == .oss, usesCustomDomain {
            if trimmedEndpoint.isEmpty { errors.append("Enter the custom domain") }
            if customDomainBucket.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the bucket bound to the custom domain") }
        }
        if !(5...5_120).contains(partSizeMiB) { errors.append("Part size must be between 5 MiB and 5 GiB") }
        return errors
    }

    public struct ConfigurationError: Error, LocalizedError, Sendable {
        public let messages: [String]
        public var errorDescription: String? { messages.joined(separator: "\n") }
    }

    public func storageConfiguration() throws -> StorageConfiguration {
        let errors = validationErrors.filter { $0 != "Enter the access key ID" }
        guard errors.isEmpty else { throw ConfigurationError(messages: errors) }
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespaces)
        let parsedEndpoint = trimmedEndpoint.isEmpty ? nil : StorageEndpoint(string: trimmedEndpoint)
        return StorageConfiguration(provider: kind.provider, endpoint: parsedEndpoint, region: region.trimmingCharacters(in: .whitespaces),
                                    addressing: addressing, ossEndpointKind: ossEndpointKind,
                                    customDomainBucket: kind.provider == .oss && usesCustomDomain ? customDomainBucket.trimmingCharacters(in: .whitespaces) : nil,
                                    ossSignatureVersion: ossSignatureVersion, listAPIVersion: listAPIVersion)
    }

    public var partSizeBytes: Int64 { Int64(min(max(partSizeMiB, 5), 5_120)) << 20 }

    public static func recents(_ accounts: [StorageAccount]) -> [StorageAccount] {
        accounts.filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }
}
