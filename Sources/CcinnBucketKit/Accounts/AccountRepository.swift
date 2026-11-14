import Foundation
import os
import Security
import StorageSigning

// MARK: - Secrets

public struct SecretKey: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case secretAccessKey
        case sessionToken
    }

    public let accountID: UUID
    public let kind: Kind

    public init(accountID: UUID, kind: Kind) {
        self.accountID = accountID
        self.kind = kind
    }

    var account: String { "\(accountID.uuidString).\(kind.rawValue)" }
}

public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    /// Stores `value`, or deletes the secret when `value` is nil or empty.
    func setSecret(_ value: String?, for key: SecretKey) throws
}

public struct SecretStoreError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// macOS Keychain (generic passwords, this-device-only, available after first unlock).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "io.github.whiteccinn.ccinnbucket.accounts") {
        self.service = service
    }

    public func secret(for key: SecretKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError(message: "Keychain read failed (\(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError(message: "Keychain delete failed (\(status))")
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "CcinnBucket account secret"
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw SecretStoreError(message: "Keychain write failed (\(status))") }
        } else if update != errSecSuccess {
            throw SecretStoreError(message: "Keychain update failed (\(update))")
        }
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock<[SecretKey: String]>(initialState: [:])

    public init() {}

    public func secret(for key: SecretKey) throws -> String? { storage.withLock { $0[key] } }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { $0[key] = value?.isEmpty == false ? value : nil }
    }
}

// MARK: - Repository

/// Persists accounts as JSON (atomic writes, owner-only permissions) and their secrets in a `SecretStore`.
public final class AccountRepository: Sendable {
    public let directory: URL
    private let secrets: any SecretStore

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CcinnBucket", isDirectory: true)
    }

    public init(directory: URL = AccountRepository.defaultDirectory, secrets: any SecretStore = KeychainSecretStore()) {
        self.directory = directory
        self.secrets = secrets
    }

    private var fileURL: URL { directory.appendingPathComponent("accounts.json") }

    public func load() throws -> [StorageAccount] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard data.count < 16 << 20 else { throw SecretStoreError(message: "The accounts file is unexpectedly large.") }
        return try JSONDecoder().decode([StorageAccount].self, from: data)
    }

    public func save(_ accounts: [StorageAccount]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(accounts).write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func storeSecrets(for account: StorageAccount, secretAccessKey: String?, sessionToken: String?) throws {
        try secrets.setSecret(secretAccessKey, for: SecretKey(accountID: account.id, kind: .secretAccessKey))
        try secrets.setSecret(sessionToken, for: SecretKey(accountID: account.id, kind: .sessionToken))
    }

    public func secretAccessKey(for account: StorageAccount) -> String? {
        try? secrets.secret(for: SecretKey(accountID: account.id, kind: .secretAccessKey))
    }

    public func sessionToken(for account: StorageAccount) -> String? {
        try? secrets.secret(for: SecretKey(accountID: account.id, kind: .sessionToken))
    }

    /// Signing credentials for an account, or nil when no secret is stored.
    public func credentials(for account: StorageAccount) -> SigningCredentials? {
        guard let secret = secretAccessKey(for: account), !secret.isEmpty else { return nil }
        return SigningCredentials(accessKeyID: account.accessKeyID.trimmingCharacters(in: .whitespaces), secretAccessKey: secret,
                                  sessionToken: sessionToken(for: account))
    }

    public func delete(_ account: StorageAccount) throws {
        try secrets.setSecret(nil, for: SecretKey(accountID: account.id, kind: .secretAccessKey))
        try secrets.setSecret(nil, for: SecretKey(accountID: account.id, kind: .sessionToken))
    }
}
