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

/// What a window opened by this process connects with. Kept in memory only (see `WindowHandoff`).
struct WindowConnection {
    let account: StorageAccount
    let credentials: SigningCredentials
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
    /// Export or import of connections, shown as a sheet over whatever the window shows.
    var connectionTransfer: ConnectionTransferRequest?
    private var connectTask: Task<Void, Never>?
    /// Shared by every window of this process: hands accounts and credentials to the windows they open.
    private let handoff: WindowHandoff<WindowConnection>

    init(handoff: WindowHandoff<WindowConnection>) {
        self.handoff = handoff
    }

    var workspace: WorkspaceModel? {
        if case let .connected(model) = phase { return model }
        return nil
    }

    /// - Parameters:
    ///   - overrideCredentials: used by launch arguments; never persisted.
    func connect(account: StorageAccount, store: AccountStore, overrideCredentials: SigningCredentials? = nil,
                 then: (@MainActor (WorkspaceModel) -> Void)? = nil) {
        connectError = nil
        guard let credentials = overrideCredentials ?? storedCredentials(for: account, store: store) else { return }
        phase = .connecting(name: account.displayName)
        connectTask = Task {
            do {
                let opened = try await AccountOpener.open(account: account, credentials: credentials)
                guard !Task.isCancelled else { return }
                store.markConnected(account.id)
                let workspace = WorkspaceModel(account: account, credentials: credentials, client: opened.client,
                                               storage: opened.storage, buckets: opened.buckets)
                self.phase = .connected(workspace)
                then?(workspace)
            } catch {
                guard !Task.isCancelled else { return }
                self.connectError = describe(error)
                self.phase = .accounts
            }
        }
    }

    /// Connects a window opened by a request with the account and credentials handed to it, and returns `true`.
    /// Only requests made by this process have them: for a window that macOS restores from an earlier run this returns
    /// `false` and the window is treated like a new, empty one.
    func connect(_ request: WindowRequest, store: AccountStore) -> Bool {
        guard let connection = handoff.take(request) else { return false }
        connect(account: connection.account, store: store, overrideCredentials: connection.credentials)
        return true
    }

    /// A request for another window connected like this one, with the same account and credentials
    /// (New Window with This Connection; works for unsaved accounts and secrets outside the Keychain).
    func duplicateRequest() -> WindowRequest? {
        guard let workspace else { return nil }
        let connection = WindowConnection(account: workspace.account, credentials: workspace.credentials)
        return handoff.request(for: workspace.account.id, payload: connection)
    }

    /// A request for a new window connected to a saved account, with its secrets read as Connect reads them
    /// (Open in New Window). When they are missing, this window shows why and no window opens.
    func windowRequest(for account: StorageAccount, store: AccountStore) -> WindowRequest? {
        connectError = nil
        guard let credentials = storedCredentials(for: account, store: store) else { return nil }
        return handoff.request(for: account.id, payload: WindowConnection(account: account, credentials: credentials))
    }

    private func storedCredentials(for account: StorageAccount, store: AccountStore) -> SigningCredentials? {
        if let credentials = store.repository.credentials(for: account) { return credentials }
        connectError = "No secret access key is stored for “\(account.displayName)”. Edit the account and enter it."
        return nil
    }

    func cancelConnecting() {
        connectTask?.cancel()
        connectTask = nil
        phase = .accounts
    }

    /// Ends this window's connection only. Also stops a connect in progress, so a window closed while connecting
    /// never finishes opening a workspace that nobody shows.
    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        workspace?.shutdown()
        phase = .accounts
    }
}

/// User-facing text for any error.
func describe(_ error: any Error) -> String {
    if let error = error as? StorageError { return error.description }
    if let error = error as? any LocalizedError, let description = error.errorDescription { return description }
    return error.localizedDescription
}
