import CcinnBucketKit
import Foundation
import Observation
import StorageKit
import StorageSigning

/// Builds a storage client for an account (read-only accounts are wrapped so mutations are refused).
enum AccountOpener {
    struct Opened: Sendable {
        let client: ObjectStorageClient
        let storage: any ObjectStorage
        let buckets: [BucketInfo]
    }

    static func makeClient(account: StorageAccount, credentials: SigningCredentials) throws -> (ObjectStorageClient, any ObjectStorage) {
        let configuration = try account.storageConfiguration()
        let client = ObjectStorageClient(configuration: configuration, credentials: credentials, transport: URLSessionTransport())
        let storage: any ObjectStorage = account.isReadOnly ? ReadOnlyStorage(client) : client
        return (client, storage)
    }

    /// Connects by listing buckets; when listing is denied but a default bucket is set, checks that bucket instead.
    static func open(account: StorageAccount, credentials: SigningCredentials) async throws -> Opened {
        let (client, storage) = try makeClient(account: account, credentials: credentials)
        do {
            let buckets = try await storage.listBuckets()
            return Opened(client: client, storage: storage, buckets: buckets)
        } catch let error as StorageError where error.isAccessDenied && !account.defaultBucket.isEmpty {
            try await storage.headBucket(account.defaultBucket)
            return Opened(client: client, storage: storage, buckets: [BucketInfo(name: account.defaultBucket)])
        }
    }
}

/// State of one window: choosing an account, connecting, or connected to a workspace.
@MainActor
@Observable
final class WindowSession {
    enum Phase {
        case accounts
        case connecting(name: String)
        case connected(WorkspaceModel)
    }

    var phase: Phase = .accounts
    var connectError: String?
    private var connectTask: Task<Void, Never>?

    var workspace: WorkspaceModel? {
        if case let .connected(model) = phase { return model }
        return nil
    }

    /// - Parameters:
    ///   - overrideCredentials: used by launch arguments; never persisted.
    func connect(account: StorageAccount, store: AccountStore, overrideCredentials: SigningCredentials? = nil,
                 then: (@MainActor (WorkspaceModel) -> Void)? = nil) {
        connectError = nil
        guard let credentials = overrideCredentials ?? store.repository.credentials(for: account) else {
            connectError = "No secret access key is stored for “\(account.displayName)”. Edit the account and enter it."
            return
        }
        phase = .connecting(name: account.displayName)
        connectTask = Task {
            do {
                let opened = try await AccountOpener.open(account: account, credentials: credentials)
                guard !Task.isCancelled else { return }
                store.markConnected(account.id)
                let workspace = WorkspaceModel(account: account, client: opened.client, storage: opened.storage, buckets: opened.buckets)
                self.phase = .connected(workspace)
                then?(workspace)
            } catch {
                guard !Task.isCancelled else { return }
                self.connectError = describe(error)
                self.phase = .accounts
            }
        }
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        phase = .accounts
    }

    func disconnect() {
        workspace?.shutdown()
        phase = .accounts
    }
}

/// User-facing text for any error.
func describe(_ error: any Error) -> String {
    if let error = error as? StorageError { return error.description }
    if let error = error as? LocalizedError, let description = error.errorDescription { return description }
    return error.localizedDescription
}
