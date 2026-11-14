import CcinnBucketKit
import Foundation
import Observation
import StorageKit
import StorageSigning

/// Editable copy of an account plus its secrets, with "Test connection".
@MainActor
@Observable
final class AccountDraft {
    enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    let accountID: UUID?
    var account: StorageAccount
    var secretAccessKey: String
    var sessionToken: String
    var testState: TestState = .idle
    private var testTask: Task<Void, Never>?

    init(account existing: StorageAccount?, store: AccountStore, kind: AccountKind = .amazonS3) {
        accountID = existing?.id
        account = existing ?? StorageAccount(kind: kind)
        secretAccessKey = existing.flatMap(store.secretAccessKey(for:)) ?? ""
        sessionToken = existing.flatMap(store.sessionToken(for:)) ?? ""
    }

    /// Switches provider preset, keeping name, colour and keys but resetting provider-specific defaults.
    func apply(kind: AccountKind) {
        guard kind != account.kind else { return }
        var updated = StorageAccount(id: account.id, kind: kind, name: account.name, accessKeyID: account.accessKeyID, color: account.color)
        updated.isFavorite = account.isFavorite
        updated.isReadOnly = account.isReadOnly
        updated.createdAt = account.createdAt
        updated.lastConnectedAt = account.lastConnectedAt
        updated.partSizeMiB = account.partSizeMiB
        account = updated
        testState = .idle
    }

    var validationErrors: [String] {
        var errors = account.validationErrors
        if secretAccessKey.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("Enter the secret access key") }
        return errors
    }

    var isValid: Bool { validationErrors.isEmpty }

    var credentials: SigningCredentials {
        SigningCredentials(accessKeyID: account.accessKeyID.trimmingCharacters(in: .whitespaces),
                           secretAccessKey: secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
                           sessionToken: sessionToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func normalizedAccount() -> StorageAccount {
        var normalized = account
        normalized.name = account.name.trimmingCharacters(in: .whitespaces)
        normalized.endpoint = account.endpoint.trimmingCharacters(in: .whitespaces)
        normalized.region = account.region.trimmingCharacters(in: .whitespaces)
        normalized.accessKeyID = account.accessKeyID.trimmingCharacters(in: .whitespaces)
        normalized.defaultBucket = account.defaultBucket.trimmingCharacters(in: .whitespaces)
        normalized.customDomainBucket = account.customDomainBucket.trimmingCharacters(in: .whitespaces)
        return normalized
    }

    func test() {
        testTask?.cancel()
        let account = normalizedAccount()
        let credentials = credentials
        testState = .running
        testTask = Task {
            do {
                let opened = try await AccountOpener.open(account: account, credentials: credentials)
                guard !Task.isCancelled else { return }
                var message = "Connected to \(account.effectiveEndpointDescription) · \(opened.buckets.count.formatted()) bucket\(opened.buckets.count == 1 ? "" : "s")"
                if account.kind.provider == .s3 { message += " · region \(account.region)" }
                if credentials.isTemporary { message += " · temporary credentials" }
                testState = .succeeded(message)
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failed(describe(error))
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testState = .idle
    }
}
