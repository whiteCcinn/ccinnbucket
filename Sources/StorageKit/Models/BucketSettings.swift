import Foundation

public struct SettingField: Sendable, Hashable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// One rule / grant / entry of a bucket configuration, flattened for display.
public struct SettingItem: Sendable, Hashable {
    public var title: String
    public var fields: [SettingField]

    public init(title: String, fields: [SettingField]) {
        self.title = title
        self.fields = fields
    }
}

public enum BucketSettingKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case versioning
    case lifecycle
    case cors
    case policy
    case acl
    case encryption

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .versioning: "Versioning"
        case .lifecycle: "Lifecycle"
        case .cors: "CORS"
        case .policy: "Bucket Policy"
        case .acl: "Access Control"
        case .encryption: "Default Encryption"
        }
    }

    var subresource: String {
        switch self {
        case .versioning: "versioning"
        case .lifecycle: "lifecycle"
        case .cors: "cors"
        case .policy: "policy"
        case .acl: "acl"
        case .encryption: "encryption"
        }
    }

    /// Error codes meaning "nothing configured" (S3 and OSS spellings).
    var notConfiguredCodes: Set<String> {
        switch self {
        case .versioning, .acl: []
        case .lifecycle: ["NoSuchLifecycleConfiguration", "NoSuchLifecycle"]
        case .cors: ["NoSuchCORSConfiguration"]
        case .policy: ["NoSuchBucketPolicy"]
        case .encryption: ["ServerSideEncryptionConfigurationNotFoundError", "NoSuchServerSideEncryptionRule"]
        }
    }
}

/// A bucket configuration document as shown in the settings view.
public struct BucketSettingDocument: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case configured
        case notConfigured
        case unsupported
        case failed
    }

    public var kind: BucketSettingKind
    public var state: State
    public var items: [SettingItem]
    /// Pretty-printed XML or JSON.
    public var raw: String
    public var message: String?

    public init(kind: BucketSettingKind, state: State, items: [SettingItem] = [], raw: String = "", message: String? = nil) {
        self.kind = kind
        self.state = state
        self.items = items
        self.raw = raw
        self.message = message
    }
}

/// Pure parsers turning configuration documents into display items.
public enum BucketSettingParsers {
    public static func versioning(_ root: XElement) -> (VersioningStatus, [SettingItem]) {
        let status: VersioningStatus = switch root.childText("Status") {
        case "Enabled": .enabled
        case "Suspended": .suspended
        default: .unversioned
        }
        var fields = [SettingField("Status", status.rawValue)]
        if let mfa = root.childText("MfaDelete") { fields.append(SettingField("MFA delete", mfa)) }
        return (status, [SettingItem(title: "Versioning", fields: fields)])
    }

    public static func lifecycle(_ root: XElement) -> [SettingItem] {
        root.children("Rule").enumerated().map { index, rule in
            var fields: [SettingField] = []
            fields.append(SettingField("Status", rule.childText("Status") ?? "—"))
            let filter = rule.child("Filter")
            let prefix = rule.childText("Prefix") ?? filter?.childText("Prefix") ?? filter?.path("And", "Prefix")?.text
            fields.append(SettingField("Applies to", (prefix?.isEmpty ?? true) ? "Whole bucket" : "Prefix \(prefix ?? "")"))
            let tags = (filter?.children("Tag") ?? []) + (filter?.child("And")?.children("Tag") ?? [])
            if !tags.isEmpty {
                fields.append(SettingField("Tags", tags.map { "\($0.childText("Key") ?? "")=\($0.childText("Value") ?? "")" }.joined(separator: ", ")))
            }
            for transition in rule.children("Transition") {
                let when = transition.childText("Days").map { "after \($0) days" } ?? transition.childText("Date").map { "on \($0)" } ?? ""
                fields.append(SettingField("Transition", "To \(transition.childText("StorageClass") ?? "?") \(when)"))
            }
            if let expiration = rule.child("Expiration") {
                if let days = expiration.childText("Days") { fields.append(SettingField("Expiration", "After \(days) days")) }
                if let date = expiration.childText("Date") { fields.append(SettingField("Expiration", "On \(date)")) }
                if expiration.childText("ExpiredObjectDeleteMarker") == "true" { fields.append(SettingField("Expiration", "Remove expired delete markers")) }
            }
            for transition in rule.children("NoncurrentVersionTransition") {
                fields.append(SettingField("Noncurrent transition", "To \(transition.childText("StorageClass") ?? "?") after \(transition.childText("NoncurrentDays") ?? "?") days"))
            }
            if let days = rule.child("NoncurrentVersionExpiration")?.childText("NoncurrentDays") {
                fields.append(SettingField("Noncurrent expiration", "After \(days) days"))
            }
            if let days = rule.child("AbortIncompleteMultipartUpload")?.childText("DaysAfterInitiation") {
                fields.append(SettingField("Incomplete uploads", "Abort after \(days) days"))
            }
            return SettingItem(title: rule.childText("ID").flatMap { $0.isEmpty ? nil : $0 } ?? "Rule \(index + 1)", fields: fields)
        }
    }

    public static func cors(_ root: XElement) -> [SettingItem] {
        root.children("CORSRule").enumerated().map { index, rule in
            func list(_ name: String) -> String {
                let values = rule.children(name).map(\.text)
                return values.isEmpty ? "—" : values.joined(separator: ", ")
            }
            var fields = [SettingField("Origins", list("AllowedOrigin")), SettingField("Methods", list("AllowedMethod")),
                          SettingField("Headers", list("AllowedHeader")), SettingField("Exposed headers", list("ExposeHeader"))]
            if let age = rule.childText("MaxAgeSeconds") { fields.append(SettingField("Max age", "\(age) s")) }
            return SettingItem(title: rule.childText("ID") ?? "Rule \(index + 1)", fields: fields)
        }
    }

    public static func encryption(_ root: XElement) -> [SettingItem] {
        let rules = root.name == "ServerSideEncryptionRule" ? [root] : root.children("Rule")
        return rules.enumerated().map { index, rule in
            let defaults = rule.child("ApplyServerSideEncryptionByDefault")
            var fields = [SettingField("Algorithm", defaults?.childText("SSEAlgorithm") ?? "—")]
            if let key = defaults?.childText("KMSMasterKeyID"), !key.isEmpty { fields.append(SettingField("KMS key", key)) }
            if let bucketKey = rule.childText("BucketKeyEnabled") { fields.append(SettingField("Bucket key", bucketKey)) }
            return SettingItem(title: rules.count > 1 ? "Rule \(index + 1)" : "Default encryption", fields: fields)
        }
    }

    /// Pretty-prints a JSON policy (bounded); returns the input when it is not valid JSON.
    public static func prettyJSON(_ data: Data) -> String {
        guard data.count <= 1 << 20, let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }

    public static func policy(_ data: Data) -> [SettingItem] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let statements: [[String: Any]]
        if let list = object["Statement"] as? [[String: Any]] {
            statements = list
        } else if let single = object["Statement"] as? [String: Any] {
            statements = [single]
        } else {
            statements = []
        }
        func describe(_ value: Any?) -> String {
            switch value {
            case let text as String: text
            case let list as [Any]: list.map { describe($0) }.joined(separator: ", ")
            case let map as [String: Any]: map.keys.sorted().map { "\($0): \(describe(map[$0]))" }.joined(separator: "; ")
            case nil: "—"
            default: String(describing: value ?? "—")
            }
        }
        return statements.prefix(200).enumerated().map { index, statement in
            SettingItem(title: (statement["Sid"] as? String) ?? "Statement \(index + 1)", fields: [
                SettingField("Effect", describe(statement["Effect"])),
                SettingField("Principal", describe(statement["Principal"])),
                SettingField("Action", describe(statement["Action"])),
                SettingField("Resource", describe(statement["Resource"])),
            ] + (statement["Condition"] != nil ? [SettingField("Condition", describe(statement["Condition"]))] : []))
        }
    }
}
