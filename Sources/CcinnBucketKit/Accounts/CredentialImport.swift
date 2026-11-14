import Foundation
import StorageKit

/// A credential found in a CLI configuration file. Lives only in memory until the user imports it
/// (then the secret goes to the Keychain).
public struct ImportedCredential: Sendable, Hashable, Identifiable {
    /// Human-readable file, e.g. `~/.aws/credentials`.
    public var source: String
    public var profileName: String
    public var provider: StorageProvider
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    public var region: String?
    public var endpoint: String?
    public var addressing: AddressingStyle?

    public var id: String { "\(source)#\(profileName)" }

    public init(source: String, profileName: String, provider: StorageProvider, accessKeyID: String, secretAccessKey: String,
                sessionToken: String?, region: String?, endpoint: String?, addressing: AddressingStyle?) {
        self.source = source
        self.profileName = profileName
        self.provider = provider
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.endpoint = endpoint
        self.addressing = addressing
    }

    /// An account pre-filled from this credential (without the secret, which the caller stores separately).
    public func makeAccount() -> StorageAccount {
        let kind: AccountKind
        switch provider {
        case .oss:
            kind = .alibabaOSS
        case .s3:
            if let endpoint, !endpoint.isEmpty, !(StorageEndpoint(string: endpoint)?.host.hasSuffix("amazonaws.com") ?? false) {
                kind = .otherS3
            } else {
                kind = .amazonS3
            }
        }
        var account = StorageAccount(kind: kind, name: profileName, accessKeyID: accessKeyID, color: provider == .oss ? .orange : .cyan)
        if let region, !region.isEmpty { account.region = region }
        if let endpoint, !endpoint.isEmpty {
            if provider == .oss, let regionFromHost = OSSRegion.fromEndpoint(endpoint) {
                account.region = regionFromHost
                if endpoint.contains("-internal.") { account.ossEndpointKind = .internal }
            } else {
                account.endpoint = endpoint
            }
        }
        if let addressing { account.addressing = addressing }
        return account
    }
}

enum OSSRegion {
    /// `oss-cn-shanghai.aliyuncs.com` / `https://oss-cn-shanghai-internal.aliyuncs.com` → `cn-shanghai`.
    static func fromEndpoint(_ endpoint: String) -> String? {
        guard let host = StorageEndpoint(string: endpoint)?.host, host.hasSuffix(".aliyuncs.com") else { return nil }
        for label in host.split(separator: ".") where label.hasPrefix("oss-") {
            var region = String(label.dropFirst(4))
            if region.hasSuffix("-internal") { region = String(region.dropLast(9)) }
            return region == "accelerate" ? nil : region
        }
        return nil
    }
}

/// Read-only parsers for AWS and Alibaba Cloud CLI configuration files. Never writes anything.
public enum CredentialImport {
    /// Files larger than this are ignored.
    static let maximumFileSize = 1 << 20

    // MARK: INI

    struct Section {
        var name: String
        var values: [String: String] = [:]
    }

    /// Lenient INI parser: `[section]`, `key = value`, `#`/`;` comments, and AWS-style indented sub-keys
    /// (`s3 =` followed by `  addressing_style = path` becomes `s3.addressing_style`).
    static func parseINI(_ text: String, maxSections: Int = 1_000) -> [Section] {
        var sections: [Section] = []
        var parentKey: String?
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).prefix(100_000) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
                guard sections.count < maxSections else { break }
                sections.append(Section(name: String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)))
                parentKey = nil
                continue
            }
            guard !sections.isEmpty, let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let indented = line.first == " " || line.first == "\t"
            if indented, let parentKey {
                sections[sections.count - 1].values["\(parentKey).\(key)"] = value
            } else {
                sections[sections.count - 1].values[key] = value
                parentKey = value.isEmpty ? key : nil
            }
        }
        return sections
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }

    // MARK: AWS

    /// Profiles from `~/.aws/credentials`, enriched with `region`, `endpoint_url` and `s3.addressing_style`
    /// from `~/.aws/config`. Profiles without both keys are skipped.
    public static func parseAWS(credentials: String, config: String, source: String = "~/.aws/credentials") -> [ImportedCredential] {
        var configByProfile: [String: [String: String]] = [:]
        for section in parseINI(config) {
            if section.name == "default" {
                configByProfile["default"] = section.values
            } else if section.name.hasPrefix("profile ") {
                configByProfile[String(section.name.dropFirst(8)).trimmingCharacters(in: .whitespaces)] = section.values
            }
        }
        var seen = Set<String>()
        return parseINI(credentials).compactMap { section in
            guard !seen.contains(section.name), let id = nonEmpty(section.values["aws_access_key_id"]),
                  let secret = nonEmpty(section.values["aws_secret_access_key"]) else { return nil }
            seen.insert(section.name)
            let config = configByProfile[section.name] ?? [:]
            let style = nonEmpty(config["s3.addressing_style"])?.lowercased()
            return ImportedCredential(source: source, profileName: section.name, provider: .s3, accessKeyID: id, secretAccessKey: secret,
                                      sessionToken: nonEmpty(section.values["aws_session_token"]) ?? nonEmpty(section.values["aws_security_token"]),
                                      region: nonEmpty(section.values["region"]) ?? nonEmpty(config["region"]),
                                      endpoint: nonEmpty(config["s3.endpoint_url"]) ?? nonEmpty(config["endpoint_url"]),
                                      addressing: style == "path" ? .path : (style == "virtual" ? .virtualHosted : nil))
        }
    }

    // MARK: Alibaba Cloud

    /// `~/.alibabacloud/credentials` (INI): `access_key` and `sts` profiles.
    public static func parseAlibabaCredentials(_ text: String, source: String = "~/.alibabacloud/credentials") -> [ImportedCredential] {
        parseINI(text).compactMap { section in
            let type = section.values["type"]?.lowercased() ?? "access_key"
            guard type == "access_key" || type == "sts", let id = nonEmpty(section.values["access_key_id"]),
                  let secret = nonEmpty(section.values["access_key_secret"]) else { return nil }
            return ImportedCredential(source: source, profileName: section.name, provider: .oss, accessKeyID: id, secretAccessKey: secret,
                                      sessionToken: nonEmpty(section.values["security_token"]), region: nonEmpty(section.values["region_id"]),
                                      endpoint: nil, addressing: nil)
        }
    }

    /// `~/.ossutilconfig` (`[Credentials]` with accessKeyID/accessKeySecret/stsToken/endpoint).
    public static func parseOSSUtilConfig(_ text: String, source: String = "~/.ossutilconfig") -> [ImportedCredential] {
        parseINI(text).compactMap { section in
            let values = section.values
            guard let id = nonEmpty(values["accesskeyid"]), let secret = nonEmpty(values["accesskeysecret"]) else { return nil }
            let endpoint = nonEmpty(values["endpoint"])
            return ImportedCredential(source: source, profileName: section.name == "Credentials" ? "ossutil" : section.name, provider: .oss,
                                      accessKeyID: id, secretAccessKey: secret, sessionToken: nonEmpty(values["ststoken"]),
                                      region: nonEmpty(values["region"]) ?? endpoint.flatMap(OSSRegion.fromEndpoint), endpoint: endpoint, addressing: nil)
        }
    }

    /// `~/.aliyun/config.json` (aliyun CLI): `AK` and `StsToken` profiles.
    public static func parseAliyunConfig(_ data: Data, source: String = "~/.aliyun/config.json") -> [ImportedCredential] {
        guard data.count <= maximumFileSize, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]] else { return [] }
        return profiles.prefix(1_000).compactMap { profile in
            let mode = (profile["mode"] as? String) ?? "AK"
            guard mode == "AK" || mode == "StsToken", let name = profile["name"] as? String,
                  let id = nonEmpty(profile["access_key_id"] as? String), let secret = nonEmpty(profile["access_key_secret"] as? String) else { return nil }
            return ImportedCredential(source: source, profileName: name, provider: .oss, accessKeyID: id, secretAccessKey: secret,
                                      sessionToken: nonEmpty(profile["sts_token"] as? String), region: nonEmpty(profile["region_id"] as? String),
                                      endpoint: nil, addressing: nil)
        }
    }

    // MARK: Scanning

    static func readText(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumFileSize,
              let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Reads every supported file under `home` that exists (read-only).
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportedCredential] {
        var found: [ImportedCredential] = []
        if let credentials = readText(home.appendingPathComponent(".aws/credentials")) {
            found += parseAWS(credentials: credentials, config: readText(home.appendingPathComponent(".aws/config")) ?? "")
        }
        for name in ["credentials", "credentials.ini"] {
            if let text = readText(home.appendingPathComponent(".alibabacloud/\(name)")) {
                found += parseAlibabaCredentials(text, source: "~/.alibabacloud/\(name)")
            }
        }
        if let text = readText(home.appendingPathComponent(".ossutilconfig")) { found += parseOSSUtilConfig(text) }
        if let text = readText(home.appendingPathComponent(".aliyun/config.json")) { found += parseAliyunConfig(Data(text.utf8)) }
        return found
    }
}
