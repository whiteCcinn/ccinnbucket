import CcinnBucketKit
import Foundation
import Observation
import StorageKit
import StorageSigning

/// Shared, observable list of saved accounts (persisted via `AccountRepository`; secrets in the Keychain).
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [StorageAccount] = []
    var lastError: String?
    let repository: AccountRepository

    init(repository: AccountRepository) {
        self.repository = repository
        do {
            accounts = try repository.load()
        } catch {
            lastError = "Could not read saved accounts: \(error.localizedDescription)"
        }
    }

    var favorites: [StorageAccount] { accounts.filter(\.isFavorite).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending } }
    var recents: [StorageAccount] { Array(StorageAccount.recents(accounts.filter { !$0.isFavorite }).prefix(10)) }
    var others: [StorageAccount] {
        let recentIDs = Set(recents.map(\.id))
        return accounts.filter { !$0.isFavorite && !recentIDs.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func account(id: UUID?) -> StorageAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Inserts or updates an account; secrets go to the Keychain, never to the account file.
    @discardableResult
    func save(_ account: StorageAccount, secretAccessKey: String?, sessionToken: String?) throws -> StorageAccount {
        try repository.storeSecrets(for: account, secretAccessKey: secretAccessKey, sessionToken: sessionToken)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        try persist()
        return account
    }

    /// Updates account fields only; Keychain secrets are not touched (a failed Keychain read can never erase them).
    func update(_ account: StorageAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        try? persist()
    }

    func delete(_ account: StorageAccount) {
        accounts.removeAll { $0.id == account.id }
        try? repository.delete(account)
        try? persist()
    }

    func duplicate(_ account: StorageAccount) -> StorageAccount? {
        var copy = account
        copy.id = UUID()
        copy.name = account.displayName + " copy"
        copy.lastConnectedAt = nil
        copy.createdAt = Date()
        copy.isFavorite = false
        return try? save(copy, secretAccessKey: repository.secretAccessKey(for: account), sessionToken: repository.sessionToken(for: account))
    }

    func toggleFavorite(_ account: StorageAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].isFavorite.toggle()
        try? persist()
    }

    func markConnected(_ id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].lastConnectedAt = Date()
        try? persist()
    }

    func secretAccessKey(for account: StorageAccount) -> String? { repository.secretAccessKey(for: account) }
    func sessionToken(for account: StorageAccount) -> String? { repository.sessionToken(for: account) }

    private func persist() throws {
        do {
            try repository.save(accounts)
            lastError = nil
        } catch {
            lastError = "Could not save accounts: \(error.localizedDescription)"
            throw error
        }
    }
}

/// App-wide services shared by every window.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let accounts: AccountStore
    /// Accounts and credentials on their way to windows opened by this process (in memory only).
    let windowHandoff = WindowHandoff<WindowConnection>()

    private init() {
        // `--data-dir <path>` isolates accounts (and keeps secrets in memory) for demos and visual checks.
        if let path = LaunchArguments.value("--data-dir") {
            accounts = AccountStore(repository: AccountRepository(directory: URL(fileURLWithPath: path, isDirectory: true),
                                                                  secrets: InMemorySecretStore()))
        } else {
            accounts = AccountStore(repository: AccountRepository())
        }
    }
}
