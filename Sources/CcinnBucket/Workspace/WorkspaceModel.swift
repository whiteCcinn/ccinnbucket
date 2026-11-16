import CcinnBucketKit
import Foundation
import Observation
import StorageKit
import StorageSigning

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// One connected account in one window: buckets, the open bucket's browser, transfers and notifications.
@MainActor
@Observable
final class WorkspaceModel {
    let account: StorageAccount
    /// The credentials this window connected with, kept in memory only so another window can reuse them
    /// (New Window with This Connection) when they are not in the Keychain.
    let credentials: SigningCredentials
    let client: ObjectStorageClient
    let storage: any ObjectStorage
    let transfers: TransfersModel

    var buckets: [BucketInfo]
    var bucketFilter = ""
    var isLoadingBuckets = false
    var bucketsError: String?
    private(set) var browser: BrowserModel?
    var toast: Toast?
    var showInspector = true
    var showTransfers = false
    var settingsBucket: String?
    var isCreatingBucket = false

    private var toastTask: Task<Void, Never>?
    private var bucketsTask: Task<Void, Never>?

    init(account: StorageAccount, credentials: SigningCredentials, client: ObjectStorageClient, storage: any ObjectStorage, buckets: [BucketInfo]) {
        self.account = account
        self.credentials = credentials
        self.client = client
        self.storage = storage
        self.buckets = buckets.sorted { $0.name < $1.name }
        transfers = TransfersModel(storage: storage, partSize: account.partSizeBytes)
        transfers.onJobFinished = { [weak self] job in self?.transferFinished(job) }
    }

    var isReadOnly: Bool { account.isReadOnly || storage.isReadOnly }
    var capabilities: StorageCapabilities { storage.capabilities }
    var selectedBucket: String? { browser?.bucket }

    var visibleBuckets: [BucketInfo] {
        let filter = bucketFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return buckets }
        return buckets.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    func region(of bucket: String) -> String? {
        buckets.first { $0.name == bucket }?.region ?? client.cachedLocation(of: bucket)?.region
    }

    // MARK: Buckets

    func refreshBuckets() {
        bucketsTask?.cancel()
        isLoadingBuckets = true
        bucketsError = nil
        bucketsTask = Task {
            do {
                let list = try await storage.listBuckets()
                guard !Task.isCancelled else { return }
                buckets = list.sorted { $0.name < $1.name }
            } catch {
                if !Task.isCancelled { bucketsError = describe(error) }
            }
            isLoadingBuckets = false
        }
    }

    /// Opens a bucket at a prefix (keeps the current browser when only the prefix changes).
    func open(bucket: String, prefix: String = "") {
        if let browser, browser.bucket == bucket {
            browser.navigate(to: prefix)
            return
        }
        browser?.cancelWork()
        let model = BrowserModel(bucket: bucket, prefix: prefix, workspace: self)
        browser = model
        model.reload()
    }

    func createBucket(name: String, region: String?) async -> Bool {
        do {
            try await storage.createBucket(name, region: region)
            buckets.append(BucketInfo(name: name, creationDate: Date(), region: region ?? account.region))
            buckets.sort { $0.name < $1.name }
            showToast("Created bucket “\(name)”")
            open(bucket: name)
            return true
        } catch {
            showToast(describe(error), isError: true)
            return false
        }
    }

    func deleteBucket(_ bucket: BucketInfo) async {
        do {
            try await storage.deleteBucket(bucket.name)
            buckets.removeAll { $0.name == bucket.name }
            if browser?.bucket == bucket.name {
                browser?.cancelWork()
                browser = nil
            }
            showToast("Deleted bucket “\(bucket.name)”")
        } catch let error as StorageError where error.code == "BucketNotEmpty" {
            showToast("“\(bucket.name)” is not empty. Delete its objects (and versions) first.", isError: true)
        } catch {
            showToast(describe(error), isError: true)
        }
    }

    // MARK: Transfers

    private func transferFinished(_ job: TransferJob) {
        if case .failed = job.status {
            showToast("\(job.title): \(job.failures.first?.message ?? "failed")", isError: true)
        } else if job.status == .completed, job.direction != .download {
            browser?.refreshSoon()
        } else if job.status == .completed, job.direction == .download {
            showToast("Downloaded \(job.title)")
        }
    }

    // MARK: Notifications

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: isError ? 6_000_000_000 : 3_000_000_000)
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func shutdown() {
        bucketsTask?.cancel()
        browser?.cancelWork()
        transfers.shutdown()
    }
}
