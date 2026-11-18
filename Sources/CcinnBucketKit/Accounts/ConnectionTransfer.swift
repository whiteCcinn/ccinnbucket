import CommonCrypto
import CryptoKit
import Foundation
import StorageKit

/// A connections export file: every saved connection with its settings and app preferences.
///
/// With a passphrase, connections, preferences and secret keys are all sealed together (authenticated encryption), so
/// nothing in the file can be read or changed without the passphrase. Without one, connections and preferences are
/// in the clear and no secrets are written.
public struct ConnectionExport: Codable, Sendable, Equatable {
    public static let formatIdentifier = "ccinnbucket.connections"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var appVersion: String
    public var connectionCount: Int
    /// Connections in the clear (exports without a passphrase; empty when sealed).
    public var accounts: [StorageAccount]
    /// Whitelisted app preferences (`UserDefaults` key → value) in the clear (empty when sealed).
    public var preferences: [String: String]
    /// Everything, sealed with the passphrase.
    public var sealed: SealedPayload?

    public var isEncrypted: Bool { sealed != nil }
}

/// AES-256-GCM under a key derived from the passphrase with PBKDF2-HMAC-SHA256; the file's header is the associated data.
public struct SealedPayload: Codable, Sendable, Equatable {
    public var kdf: String
    public var iterations: Int
    public var salt: Data
    public var cipher: String
    /// Nonce, ciphertext and tag (`AES.GCM.SealedBox.combined`).
    public var sealed: Data
}

/// The content of an export, readable after `ConnectionTransfer.unlock`.
public struct UnlockedConnections: Sendable, Equatable {
    public var accounts: [StorageAccount]
    public var preferences: [String: String]
    public var secrets: [UUID: ConnectionTransfer.Secrets]
}

/// Moves connections between Macs: export to one file, import with one click.
public enum ConnectionTransfer {
    public static let fileExtension = "ccinnbucket"
    public static let minimumPassphraseLength = 8
    /// OWASP's recommendation for PBKDF2-HMAC-SHA256.
    public static let defaultIterations = 600_000
    /// Round counts accepted from a file: a crafted value must not make the app hang.
    public static let acceptedIterations = 1_000...5_000_000
    public static let maximumFileSize = 8 << 20
    public static let maximumAccounts = 2_000

    private static let kdfName = "PBKDF2-HMAC-SHA256"
    private static let cipherName = "AES-256-GCM"

    /// Binds the sealed content to the file's header: changing the version, date, app version or count breaks it.
    private static func associatedData(_ file: ConnectionExport) -> Data {
        Data("\(file.format)|\(file.version)|\(file.exportedAt.timeIntervalSinceReferenceDate.bitPattern)|\(file.appVersion)|\(file.connectionCount)".utf8)
    }

    public struct Secrets: Codable, Sendable, Equatable {
        public var secretAccessKey: String?
        public var sessionToken: String?

        public init(secretAccessKey: String?, sessionToken: String?) {
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    public enum TransferError: Error, Equatable, LocalizedError {
        case notAConnectionsFile
        case unsupportedVersion(Int)
        case fileTooLarge
        case tooManyAccounts
        case weakPassphrase
        case wrongPassphrase
        case invalidKeyDerivation

        public var errorDescription: String? {
            switch self {
            case .notAConnectionsFile: "This is not a CcinnBucket connections file."
            case let .unsupportedVersion(version): "This file was exported by a newer CcinnBucket (format \(version)). Update CcinnBucket to import it."
            case .fileTooLarge: "The file is too large to be a connections export."
            case .tooManyAccounts: "The file lists more than \(ConnectionTransfer.maximumAccounts) connections."
            case .weakPassphrase: "Use a passphrase of at least \(ConnectionTransfer.minimumPassphraseLength) characters."
            case .wrongPassphrase: "The passphrase is wrong, or the file was changed after it was exported."
            case .invalidKeyDerivation: "The file's encryption settings are not supported."
            }
        }
    }

    /// The import of a file into the accounts already saved.
    public struct ImportPlan: Equatable, Sendable {
        /// A saved connection whose settings the file replaces.
        public struct Update: Equatable, Sendable {
            public var account: StorageAccount
            /// The settings that change, in words ("endpoint", "read-only", …).
            public var changes: [String]
            /// The change redirects the connection (provider, endpoint, region, access key, domain) or widens what it
            /// may do (read-only off, more AI access) while it keeps its saved secret.
            public var isSensitive: Bool
        }

        /// New connections.
        public var added: [StorageAccount]
        /// Connections with the same id (exported from this or an earlier copy) whose settings differ.
        public var updated: [Update]
        /// The same connection already exists (under another id, or unchanged): left alone.
        public var skipped: [StorageAccount]
    }

    // MARK: Export

    /// - Parameters:
    ///   - secrets: secret keys by account id; written only with a passphrase, and only for exported accounts.
    ///   - passphrase: `nil` exports without secrets.
    public static func export(_ accounts: [StorageAccount], secrets: [UUID: Secrets], passphrase: String?, preferences: [String: String],
                              appVersion: String, date: Date = Date(), iterations: Int = defaultIterations) throws -> Data {
        var file = ConnectionExport(format: ConnectionExport.formatIdentifier, version: ConnectionExport.currentVersion, exportedAt: date,
                                    appVersion: appVersion, connectionCount: accounts.count, accounts: accounts, preferences: preferences, sealed: nil)
        if let passphrase {
            guard passphrase.count >= minimumPassphraseLength else { throw TransferError.weakPassphrase }
            let exported = Set(accounts.map(\.id))
            let records = secrets.filter { exported.contains($0.key) }.map { SecretRecord(accountID: $0.key, secrets: $0.value) }
            var saltBytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else { throw TransferError.invalidKeyDerivation }
            let salt = Data(saltBytes)
            let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
            let plaintext = try JSONEncoder().encode(SealedContent(accounts: accounts, preferences: preferences, secrets: records))
            file.accounts = []
            file.preferences = [:]
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(file))
            guard let combined = box.combined else { throw TransferError.invalidKeyDerivation }
            file.sealed = SealedPayload(kdf: kdfName, iterations: iterations, salt: salt, cipher: cipherName, sealed: combined)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    // MARK: Import

    public static func read(_ data: Data) throws -> ConnectionExport {
        guard data.count <= maximumFileSize else { throw TransferError.fileTooLarge }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == ConnectionExport.formatIdentifier else {
            throw TransferError.notAConnectionsFile
        }
        guard header.version <= ConnectionExport.currentVersion else { throw TransferError.unsupportedVersion(header.version) }
        guard let file = try? JSONDecoder().decode(ConnectionExport.self, from: data) else { throw TransferError.notAConnectionsFile }
        guard file.accounts.count <= maximumAccounts, (0...maximumAccounts).contains(file.connectionCount) else { throw TransferError.tooManyAccounts }
        return file
    }

    /// The file's content: in the clear for exports without a passphrase, otherwise decrypted and authenticated.
    public static func unlock(_ file: ConnectionExport, passphrase: String?) throws -> UnlockedConnections {
        guard let sealed = file.sealed else {
            return UnlockedConnections(accounts: file.accounts, preferences: file.preferences, secrets: [:])
        }
        guard sealed.kdf == kdfName, sealed.cipher == cipherName, acceptedIterations.contains(sealed.iterations), sealed.salt.count >= 16 else {
            throw TransferError.invalidKeyDerivation
        }
        guard let passphrase else { throw TransferError.wrongPassphrase }
        let key = try deriveKey(passphrase: passphrase, salt: sealed.salt, iterations: sealed.iterations)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.sealed), using: key, authenticating: associatedData(file))
        } catch {
            throw TransferError.wrongPassphrase
        }
        guard let content = try? JSONDecoder().decode(SealedContent.self, from: plaintext) else { throw TransferError.wrongPassphrase }
        guard content.accounts.count <= maximumAccounts else { throw TransferError.tooManyAccounts }
        var secrets: [UUID: Secrets] = [:]
        for record in content.secrets { secrets[record.accountID] = record.secrets }
        return UnlockedConnections(accounts: content.accounts, preferences: content.preferences, secrets: secrets)
    }

    public static func plan(_ incoming: [StorageAccount], existing: [StorageAccount]) -> ImportPlan {
        var identities = Set(existing.map(identity))
        var plan = ImportPlan(added: [], updated: [], skipped: [])
        var seenIDs = Set<UUID>()
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for account in incoming where seenIDs.insert(account.id).inserted {
            if let current = existingByID[account.id] {
                let (changes, isSensitive) = differences(from: current, to: account)
                if changes.isEmpty {
                    plan.skipped.append(account)
                } else {
                    plan.updated.append(ImportPlan.Update(account: account, changes: changes, isSensitive: isSensitive))
                }
            } else if identities.contains(identity(account)) {
                plan.skipped.append(account)
            } else {
                plan.added.append(account)
                identities.insert(identity(account))
            }
        }
        return plan
    }

    /// The settings that differ, in words, and whether any of them redirects the connection or widens its access.
    static func differences(from old: StorageAccount, to new: StorageAccount) -> (changes: [String], isSensitive: Bool) {
        var changes: [String] = []
        var sensitive = false
        func compare<Value: Equatable>(_ label: String, _ lhs: Value, _ rhs: Value, sensitive isSensitive: Bool = false) {
            guard lhs != rhs else { return }
            changes.append(label)
            if isSensitive { sensitive = true }
        }
        compare("name", old.name, new.name)
        compare("colour", old.color, new.color)
        compare("favourite", old.isFavorite, new.isFavorite)
        compare("provider", old.kind, new.kind, sensitive: true)
        compare("endpoint", old.endpoint, new.endpoint, sensitive: true)
        compare("region", old.region, new.region, sensitive: true)
        compare("addressing", old.addressing, new.addressing, sensitive: true)
        compare("OSS endpoint type", old.ossEndpointKind, new.ossEndpointKind, sensitive: true)
        compare("signature", old.ossSignatureVersion, new.ossSignatureVersion)
        compare("custom domain", "\(old.usesCustomDomain)/\(old.customDomainBucket)", "\(new.usesCustomDomain)/\(new.customDomainBucket)", sensitive: true)
        compare("list API", old.listAPIVersion, new.listAPIVersion)
        compare("access key ID", old.accessKeyID, new.accessKeyID, sensitive: true)
        compare("default bucket", old.defaultBucket, new.defaultBucket)
        compare("read-only", old.isReadOnly, new.isReadOnly, sensitive: old.isReadOnly && !new.isReadOnly)
        compare("part size", old.partSizeMiB, new.partSizeMiB)
        compare("AI access", old.mcpAccess, new.mcpAccess, sensitive: rank(new.mcpAccess) > rank(old.mcpAccess))
        return (changes, sensitive)
    }

    private static func rank(_ access: MCPAccess) -> Int {
        switch access {
        case .disabled: 0
        case .readOnly: 1
        case .readWrite: 2
        }
    }

    /// What makes two saved accounts the same connection (names, colours and favourites aside).
    static func identity(_ account: StorageAccount) -> String {
        var endpoint = account.endpoint.trimmingCharacters(in: .whitespaces).lowercased()
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        return [account.kind.rawValue, endpoint, account.region.trimmingCharacters(in: .whitespaces).lowercased(),
                account.accessKeyID.trimmingCharacters(in: .whitespaces), account.ossEndpointKind.rawValue,
                account.usesCustomDomain ? account.customDomainBucket : ""].joined(separator: "\u{1F}")
    }

    // MARK: Crypto

    private struct Header: Decodable {
        var format: String
        var version: Int
    }

    private struct SecretRecord: Codable {
        var accountID: UUID
        var secrets: Secrets
    }

    private struct SealedContent: Codable {
        var accounts: [StorageAccount]
        var preferences: [String: String]
        var secrets: [SecretRecord]
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard iterations > 0, iterations <= UInt32.max else { throw TransferError.invalidKeyDerivation }
        // A C string keeps the pointer valid even for an empty passphrase (no force-unwrapped buffer).
        let passwordLength = passphrase.utf8.count
        let saltBytes = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passphrase.withCString { password in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, passwordLength, saltBytes, saltBytes.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count)
        }
        guard status == kCCSuccess else { throw TransferError.invalidKeyDerivation }
        return SymmetricKey(data: derived)
    }
}
