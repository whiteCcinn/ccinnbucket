import AppKit
import CcinnBucketKit
import Foundation
import Observation
import StorageKit

/// The object browser for one bucket: prefix navigation, paged listing, sorting, selection, versions and
/// every object operation. Network work runs in cancellable tasks; results are applied only if they still
/// belong to the current listing generation.
@MainActor
@Observable
final class BrowserModel {
    enum Mode: Equatable {
        case objects
        case versions
    }

    enum Sheet: Identifiable {
        case newFolder
        case rename(ListingRow)
        case transfer(rows: [ListingRow], move: Bool)
        case presign(ListingRow)
        case preview(ListingRow)

        var id: String {
            switch self {
            case .newFolder: "new-folder"
            case let .rename(row): "rename-" + row.id
            case let .transfer(rows, move): (move ? "move-" : "copy-") + rows.map(\.id).joined(separator: "|")
            case let .presign(row): "presign-" + row.id
            case let .preview(row): "preview-" + row.id
            }
        }
    }

    struct DeleteRequest: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var objects: [ObjectReference]
        var permanent: Bool
    }

    struct UploadConflict: Identifiable {
        let id = UUID()
        var entries: [UploadEntry]
        var existing: Set<String>
    }

    let bucket: String
    let storage: any ObjectStorage
    private weak var workspace: WorkspaceModel?

    private(set) var history: NavigationHistory
    var filterText = "" { didSet { if filterText != oldValue { scheduleFilterReload() } } }
    private(set) var mode: Mode = .objects
    private(set) var rows: [ListingRow] = []
    /// Increments whenever `rows` changes so the table knows to reload.
    private(set) var rowsRevision = 0
    private var accumulator: ListingAccumulator
    private var versionFolders: [ListingRow] = []
    private var versionItems: [ListingRow] = []
    private var versionMarker: (key: String?, version: String?) = (nil, nil)
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isLoadingAll = false
    var error: String?
    private(set) var hasMore = false
    private(set) var sortColumn: ListingSortColumn = .name
    private(set) var sortAscending = true
    var selection: Set<String> = [] { didSet { if selection != oldValue { selectionChanged() } } }
    private(set) var inspector: InspectorModel?
    var sheet: Sheet?
    var pendingDelete: DeleteRequest?
    var pendingUploadConflict: UploadConflict?
    /// Progress text while counting objects for an operation (cancellable).
    private(set) var busyMessage: String?

    private var loadTask: Task<Void, Never>?
    private var sortTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var busyTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    /// Folder operations refuse to enumerate more keys than this (memory and safety bound).
    static let enumerationLimit = 1_000_000

    init(bucket: String, prefix: String, workspace: WorkspaceModel) {
        self.bucket = bucket
        storage = workspace.storage
        self.workspace = workspace
        history = NavigationHistory(start: BrowserLocation(bucket: bucket, prefix: prefix))
        accumulator = ListingAccumulator(prefix: prefix)
    }

    var prefix: String { history.current.prefix }
    var isReadOnly: Bool { workspace?.isReadOnly ?? true }
    var breadcrumbs: [ObjectPath.Crumb] { ObjectPath.breadcrumbs(prefix: prefix) }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var canGoUp: Bool { ObjectPath.parent(of: prefix) != nil }
    var selectedRows: [ListingRow] { rows.filter { selection.contains($0.id) } }
    var folderCount: Int { mode == .objects ? accumulator.folderCount : versionFolders.count }
    var objectCount: Int { mode == .objects ? accumulator.objectCount : versionItems.count }
    var loadedBytes: Int64 { mode == .objects ? accumulator.totalBytes : versionItems.reduce(0) { $0 &+ $1.size } }

    // MARK: Navigation

    func navigate(to prefix: String) {
        guard prefix != self.prefix else { return }
        history.visit(BrowserLocation(bucket: bucket, prefix: prefix))
        locationChanged()
    }

    func goBack() {
        guard history.goBack() != nil else { return }
        locationChanged()
    }

    func goForward() {
        guard history.goForward() != nil else { return }
        locationChanged()
    }

    func goUp() {
        guard let parent = ObjectPath.parent(of: prefix) else { return }
        navigate(to: parent)
    }

    private func locationChanged() {
        if !filterText.isEmpty {
            filterTask?.cancel()
            filterText = ""
        }
        selection = []
        reload()
    }

    /// Opens a folder, or previews an object.
    func open(_ row: ListingRow) {
        if row.isFolder {
            navigate(to: row.key)
        } else if !(row.version?.isDeleteMarker ?? false) {
            sheet = .preview(row)
        }
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        selection = []
        reload()
    }

    // MARK: Listing

    func cancelWork() {
        loadTask?.cancel()
        sortTask?.cancel()
        filterTask?.cancel()
        busyTask?.cancel()
        refreshTask?.cancel()
        inspector?.cancel()
    }

    func reload() {
        loadTask?.cancel()
        sortTask?.cancel()
        generation += 1
        let current = generation
        accumulator = ListingAccumulator(prefix: prefix)
        versionFolders = []
        versionItems = []
        versionMarker = (nil, nil)
        hasMore = false
        isLoadingAll = false
        error = nil
        isLoading = true
        applyRows([], keepSelection: true)
        loadTask = Task { [weak self] in
            await self?.loadNextPage(generation: current)
            self?.isLoading = false
        }
    }

    /// Reloads shortly (coalesces bursts, e.g. many finished transfers).
    func refreshSoon() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func scheduleFilterReload() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func loadMoreIfNeeded() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        let current = generation
        loadTask = Task { [weak self] in
            await self?.loadNextPage(generation: current)
            self?.isLoadingMore = false
        }
    }

    /// Loads every remaining page (cancellable with `stopLoadingAll`).
    func loadAll() {
        guard hasMore, !isLoadingAll else { return }
        loadTask?.cancel()
        isLoadingAll = true
        isLoadingMore = true
        let current = generation
        loadTask = Task { [weak self] in
            while let self, self.generation == current, self.hasMore, !Task.isCancelled {
                await self.loadNextPage(generation: current)
                if self.error != nil { break }
            }
            self?.isLoadingAll = false
            self?.isLoadingMore = false
        }
    }

    func stopLoadingAll() {
        loadTask?.cancel()
        isLoadingAll = false
        isLoadingMore = false
    }

    private func loadNextPage(generation current: Int) async {
        let listingPrefix = ObjectPath.listingPrefix(folder: prefix, filter: filterText)
        do {
            switch mode {
            case .objects:
                let token = accumulator.nextToken
                let page = try await storage.listObjects(ListObjectsRequest(bucket: bucket, prefix: listingPrefix, token: token))
                guard current == generation, !Task.isCancelled else { return }
                accumulator.append(page)
                hasMore = !accumulator.isComplete
                await present(accumulator.folders + accumulator.objects, generation: current)
            case .versions:
                let page = try await storage.listObjectVersions(VersionListRequest(bucket: bucket, prefix: listingPrefix, keyMarker: versionMarker.key,
                                                                                    versionIDMarker: versionMarker.version))
                guard current == generation, !Task.isCancelled else { return }
                let known = Set(versionFolders.map(\.key))
                versionFolders += page.commonPrefixes.filter { !known.contains($0) }.map { ListingRow.folder($0, prefix: prefix) }
                versionItems += ListingRow.versionRows(page.versions, prefix: prefix)
                versionMarker = (page.nextKeyMarker, page.nextVersionIDMarker)
                hasMore = page.isTruncated && (page.nextKeyMarker != nil || page.nextVersionIDMarker != nil)
                await present(versionFolders + versionItems, generation: current)
            }
        } catch {
            guard current == generation else { return }
            let wrapped = StorageError.wrap(error)
            if !wrapped.isCancellation { self.error = wrapped.description }
            hasMore = false
        }
    }

    /// Sorts (off the main actor for large listings) and publishes rows.
    private func present(_ unsorted: [ListingRow], generation current: Int) async {
        let column = sortColumn
        let ascending = sortAscending
        let preserveServerOrder = mode == .versions && column == .name && ascending
        let sorted: [ListingRow]
        if preserveServerOrder {
            sorted = unsorted.filter(\.isFolder) + unsorted.filter { !$0.isFolder }
        } else if unsorted.count > 3_000 {
            sorted = await Task.detached(priority: .userInitiated) { ListingSorter.sorted(unsorted, by: column, ascending: ascending) }.value
        } else {
            sorted = ListingSorter.sorted(unsorted, by: column, ascending: ascending)
        }
        guard current == generation else { return }
        applyRows(sorted, keepSelection: true)
    }

    func setSort(_ column: ListingSortColumn, ascending: Bool) {
        guard column != sortColumn || ascending != sortAscending else { return }
        sortColumn = column
        sortAscending = ascending
        let current = generation
        let unsorted = mode == .objects ? accumulator.folders + accumulator.objects : versionFolders + versionItems
        sortTask?.cancel()
        sortTask = Task { [weak self] in await self?.present(unsorted, generation: current) }
    }

    private func applyRows(_ newRows: [ListingRow], keepSelection: Bool) {
        rows = newRows
        rowsRevision &+= 1
        if keepSelection, !selection.isEmpty {
            let ids = Set(newRows.map(\.id))
            let kept = selection.intersection(ids)
            if kept != selection { selection = kept }
        }
    }

    private func selectionChanged() {
        inspector?.cancel()
        let selected = selectedRows
        if selected.count == 1, let row = selected.first, !row.isFolder, !(row.version?.isDeleteMarker ?? false) {
            let model = InspectorModel(row: row, bucket: bucket, storage: storage, workspace: workspace)
            inspector = model
            model.load()
        } else {
            inspector = nil
        }
    }

    /// Selects a key once it is listed (used by deep links).
    func select(key: String) {
        if let row = rows.first(where: { $0.key == key || $0.key == key + "/" }) { selection = [row.id] }
    }

    // MARK: Operations — helpers

    private func toast(_ message: String, isError: Bool = false) { workspace?.showToast(message, isError: isError) }

    private func refuseIfReadOnly() -> Bool {
        guard isReadOnly else { return false }
        toast(StorageError.readOnly.message, isError: true)
        return true
    }

    /// Runs `body` with a cancellable "busy" message (counting objects etc.).
    private func runBusy(_ message: String, _ body: @escaping @MainActor () async throws -> Void) {
        busyTask?.cancel()
        busyMessage = message
        busyTask = Task { [weak self] in
            do {
                try await body()
            } catch {
                let wrapped = StorageError.wrap(error)
                if !wrapped.isCancellation { self?.toast(wrapped.description, isError: true) }
            }
            self?.busyMessage = nil
        }
    }

    func cancelBusy() {
        busyTask?.cancel()
        busyMessage = nil
    }

    private func updateBusy(_ message: String) { busyMessage = message }

    /// Visits every object under `prefix` page by page on the main actor (each page is ≤ 1,000 entries).
    private func forEachPage(prefix: String, _ body: ([ObjectEntry]) throws -> Bool) async throws {
        var token: ListToken?
        repeat {
            try Task.checkCancellation()
            let page = try await storage.listObjects(ListObjectsRequest(bucket: bucket, prefix: prefix, delimiter: nil, token: token))
            if !page.objects.isEmpty, try !body(page.objects) { return }
            token = page.isTruncated ? page.nextToken : nil
        } while token != nil
    }

    /// Expands rows into objects (folders enumerate every key under their prefix).
    private func expand(_ rows: [ListingRow]) async throws -> [ObjectEntry] {
        var objects: [ObjectEntry] = []
        for row in rows {
            switch row.kind {
            case .object:
                objects.append(ObjectEntry(key: row.key, size: row.size, lastModified: row.lastModified, eTag: row.eTag, storageClass: row.storageClass))
            case .version:
                if let version = row.version, !version.isDeleteMarker {
                    objects.append(ObjectEntry(key: version.key, size: version.size, lastModified: version.lastModified, eTag: version.eTag))
                }
            case .folder:
                try await forEachPage(prefix: row.key) { page in
                    objects.append(contentsOf: page)
                    guard objects.count <= Self.enumerationLimit else {
                        throw StorageError.invalidRequest("More than \(Self.enumerationLimit.formatted()) objects are involved; work on a smaller folder.")
                    }
                    updateBusy("Counting… \(objects.count.formatted()) objects")
                    return true
                }
            }
        }
        return objects
    }

    // MARK: Upload

    func upload(_ urls: [URL], into folder: String? = nil) {
        guard !urls.isEmpty, !refuseIfReadOnly() else { return }
        let destination = folder ?? prefix
        runBusy("Preparing upload…") { [weak self] in
            guard let self else { return }
            let entries = try await Task.detached(priority: .userInitiated) { try UploadPlanner.plan(urls, destinationPrefix: destination) }.value
            guard !entries.isEmpty else {
                self.toast("Nothing to upload (hidden files and links are skipped).")
                return
            }
            let existing = try await self.existingKeys(for: entries, under: destination)
            if existing.isEmpty {
                await self.enqueueUpload(entries, destination: destination)
            } else {
                self.pendingUploadConflict = UploadConflict(entries: entries, existing: existing)
            }
        }
    }

    /// Keys of `entries` that already exist (checked with HEAD for few files, a bounded listing otherwise).
    private func existingKeys(for entries: [UploadEntry], under destination: String) async throws -> Set<String> {
        let wanted = Set(entries.map(\.key))
        if entries.count <= 20 {
            var found = Set<String>()
            for entry in entries {
                if (try? await storage.headObject(bucket: bucket, key: entry.key, versionID: nil)) != nil { found.insert(entry.key) }
            }
            return found
        }
        var found = Set<String>()
        var seen = 0
        let roots = Set(entries.map { entry -> String in
            let relative = entry.key.dropFirst(destination.count)
            if let slash = relative.firstIndex(of: "/") { return destination + relative[...slash] }
            return destination
        })
        for root in roots {
            try await forEachPage(prefix: root) { page in
                for object in page where wanted.contains(object.key) { found.insert(object.key) }
                seen += page.count
                return seen < 200_000
            }
        }
        return found
    }

    func resolveUploadConflict(replace: Bool) {
        guard let conflict = pendingUploadConflict else { return }
        pendingUploadConflict = nil
        let entries = replace ? conflict.entries : conflict.entries.filter { !conflict.existing.contains($0.key) }
        guard !entries.isEmpty else { return }
        Task { await enqueueUpload(entries, destination: prefix) }
    }

    private func enqueueUpload(_ entries: [UploadEntry], destination: String) async {
        guard let workspace else { return }
        let items = entries.map { entry in
            TransferItem(kind: .upload(file: entry.file, bucket: bucket, key: entry.key,
                                       options: ObjectWriteOptions(contentType: ContentTypes.guess(forKey: entry.key))), size: entry.size)
        }
        let title = entries.count == 1 ? ObjectPath.lastComponent(of: entries[0].key) : "\(entries.count.formatted()) files"
        await workspace.transfers.enqueue(title: title, subtitle: "to \(bucket)/\(destination)", direction: .upload, items: items)
        workspace.showTransfers = true
    }

    // MARK: Download

    func download(_ rows: [ListingRow], to directory: URL) {
        guard !rows.isEmpty else { return }
        runBusy("Preparing download…") { [weak self] in
            guard let self, let workspace = self.workspace else { return }
            var items: [TransferItem] = []
            var reserved = Set<String>()
            for row in rows {
                let objects = try await self.expand([row])
                for object in objects {
                    guard var url = LocalPathMapper.localURL(forKey: object.key, relativeTo: self.prefix, root: directory) else { continue }
                    url = LocalPathMapper.uniqueURL(for: url)
                    while reserved.contains(url.path) {
                        url = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) copy"
                            + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"))
                    }
                    reserved.insert(url.path)
                    let versionID = row.kind == .version ? row.version?.versionID : nil
                    items.append(TransferItem(kind: .download(bucket: self.bucket, key: object.key, versionID: versionID, destination: url), size: object.size))
                }
            }
            guard !items.isEmpty else {
                self.toast("There is nothing to download.")
                return
            }
            let title = rows.count == 1 ? rows[0].name : "\(items.count.formatted()) files"
            await workspace.transfers.enqueue(title: title, subtitle: "to \(directory.path)", direction: .download, items: items)
            workspace.showTransfers = true
        }
    }

    func chooseDownloadDestination(for rows: [ListingRow]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.message = rows.count == 1 ? "Choose where to save “\(rows[0].name)”." : "Choose where to save \(rows.count) items."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        download(rows, to: url)
    }

    // MARK: Delete

    func requestDelete(_ rows: [ListingRow]) {
        guard !rows.isEmpty, !refuseIfReadOnly() else { return }
        if rows.allSatisfy({ $0.kind == .version }) {
            let references = rows.compactMap { row in row.version.map { ObjectReference(key: $0.key, versionID: $0.versionID) } }
            pendingDelete = DeleteRequest(
                title: references.count == 1 ? "Permanently delete this version?" : "Permanently delete \(references.count.formatted()) versions?",
                message: "Specific versions and delete markers are removed for good. This cannot be undone.", objects: references, permanent: true)
            return
        }
        runBusy("Counting objects…") { [weak self] in
            guard let self else { return }
            let objects = try await self.expand(rows.filter { $0.kind != .version })
            let markers = rows.filter(\.isFolder).map { ObjectReference(key: $0.key) }
            var references = objects.map { ObjectReference(key: $0.key) }
            let known = Set(references.map(\.key))
            references += markers.filter { !known.contains($0.key) }
            let bytes = objects.reduce(Int64(0)) { $0 &+ $1.size }
            let versioned = (try? await self.storage.versioningStatus(bucket: self.bucket)) == .enabled
            let what = objects.count == 1 && rows.count == 1 && !rows[0].isFolder ? "“\(rows[0].name)”" : "\(objects.count.formatted()) objects"
            var message = objects.isEmpty ? "The folder is empty." : "\(SizeFormat.bytes(bytes)) in \(objects.count.formatted()) objects will be deleted."
            message += versioned ? " Versioning is enabled, so delete markers are added and earlier versions are kept."
                : " This cannot be undone."
            self.pendingDelete = DeleteRequest(title: "Delete \(what)?", message: message, objects: references, permanent: !versioned)
        }
    }

    func confirmDelete() {
        guard let request = pendingDelete, let workspace else { return }
        pendingDelete = nil
        guard !refuseIfReadOnly() else { return }
        var items: [TransferItem] = []
        var start = 0
        while start < request.objects.count {
            let batch = Array(request.objects[start..<min(start + 1_000, request.objects.count)])
            items.append(TransferItem(kind: .delete(bucket: bucket, objects: batch), size: Int64(batch.count)))
            start += batch.count
        }
        selection = []
        Task {
            await workspace.transfers.enqueue(title: request.objects.count == 1 ? ObjectPath.lastComponent(of: request.objects[0].key)
                                              : "\(request.objects.count.formatted()) objects",
                                              subtitle: "from \(bucket)", direction: .delete, items: items)
        }
    }

    // MARK: Create, rename, copy, move

    func createFolder(named name: String) async -> String? {
        if let problem = KeyRewrite.validateName(name) { return problem }
        guard !refuseIfReadOnly() else { return StorageError.readOnly.message }
        let key = prefix + name + "/"
        do {
            _ = try await storage.putObject(bucket: bucket, key: key, body: Data(), options: ObjectWriteOptions(contentType: "application/x-directory"),
                                            progress: nil)
            toast("Created folder “\(name)”")
            reload()
            return nil
        } catch {
            return describe(error)
        }
    }

    func rename(_ row: ListingRow, to newName: String) async -> String? {
        if let problem = KeyRewrite.validateName(newName) { return problem }
        guard !refuseIfReadOnly() else { return StorageError.readOnly.message }
        let newKey = KeyRewrite.renamed(key: row.key, newName: newName)
        guard newKey != row.key else { return nil }
        do {
            if row.isFolder {
                let probe = try await storage.listObjects(ListObjectsRequest(bucket: bucket, prefix: newKey, delimiter: nil, maxKeys: 1))
                if !probe.objects.isEmpty { return "A folder named “\(newName)” already exists." }
            } else if (try? await storage.headObject(bucket: bucket, key: newKey, versionID: nil)) != nil {
                return "An object named “\(newName)” already exists."
            }
        } catch {
            return describe(error)
        }
        transfer([row], toBucket: bucket, prefix: ObjectPath.parent(of: row.key) ?? "", move: true, renameTo: newName)
        return nil
    }

    /// Copies or moves rows to `bucket`/`prefix` by server-side copy (folders keep their name).
    func transfer(_ rows: [ListingRow], toBucket destinationBucket: String, prefix destinationPrefix: String, move: Bool, renameTo: String? = nil) {
        guard !rows.isEmpty, !refuseIfReadOnly() else { return }
        for row in rows where row.isFolder && destinationBucket == bucket && destinationPrefix.hasPrefix(row.key) {
            toast("Cannot \(move ? "move" : "copy") “\(row.name)” into itself.", isError: true)
            return
        }
        runBusy("Preparing…") { [weak self] in
            guard let self, let workspace = self.workspace else { return }
            var items: [TransferItem] = []
            for row in rows {
                let newBase = destinationPrefix + (renameTo ?? row.name) + (row.isFolder ? "/" : "")
                for object in try await self.expand([row]) {
                    let destinationKey = row.isFolder ? KeyRewrite.moved(key: object.key, from: row.key, to: newBase) : newBase
                    if destinationBucket == self.bucket && destinationKey == object.key { continue }
                    let request = CopyObjectRequest(sourceBucket: self.bucket, sourceKey: object.key,
                                                    sourceVersionID: row.kind == .version ? row.version?.versionID : nil,
                                                    destinationBucket: destinationBucket, destinationKey: destinationKey)
                    items.append(TransferItem(kind: .copy(request, size: object.size, deleteSource: move), size: object.size))
                }
            }
            guard !items.isEmpty else {
                self.toast("Nothing to \(move ? "move" : "copy").")
                return
            }
            let verb = renameTo != nil ? "Renaming" : (move ? "Moving" : "Copying")
            let title = rows.count == 1 ? "\(verb) \(rows[0].name)" : "\(verb) \(items.count.formatted()) objects"
            await workspace.transfers.enqueue(title: title, subtitle: "to \(destinationBucket)/\(destinationPrefix)",
                                              direction: move ? .move : .copy, items: items)
        }
    }

    // MARK: Versions

    func restore(_ row: ListingRow) {
        guard let version = row.version, !version.isDeleteMarker, !refuseIfReadOnly() else { return }
        runBusy("Restoring version…") { [weak self] in
            guard let self else { return }
            _ = try await ServerSideCopier(storage: self.storage).copy(
                CopyObjectRequest(sourceBucket: self.bucket, sourceKey: version.key, sourceVersionID: version.versionID,
                                  destinationBucket: self.bucket, destinationKey: version.key), knownSize: version.size)
            self.toast("Restored “\(row.name)” from version \(version.versionID.prefix(12))…")
            self.reload()
        }
    }

    // MARK: Sharing

    func presignedURL(for row: ListingRow, expires: Int, downloadName: String?) async throws -> URL {
        let disposition = downloadName.map { name -> String in
            let ascii = name.unicodeScalars.allSatisfy { $0.isASCII && $0 != "\"" && $0.value >= 0x20 } ? name : "download"
            return "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "download")"
        }
        return try await storage.presignedURL(bucket: bucket, key: row.key, versionID: row.version?.versionID, method: "GET",
                                              expires: expires, responseContentDisposition: disposition)
    }

    func copyKey(_ rows: [ListingRow]) {
        Pasteboard.copy(rows.map(\.key).joined(separator: "\n"))
        toast(rows.count == 1 ? "Copied key" : "Copied \(rows.count) keys")
    }

    func copyURI(_ rows: [ListingRow]) {
        let scheme = storage.capabilities.provider == .oss ? "oss" : "s3"
        Pasteboard.copy(rows.map { "\(scheme)://\(bucket)/\($0.key)" }.joined(separator: "\n"))
        toast(rows.count == 1 ? "Copied \(scheme):// URI" : "Copied \(rows.count) URIs")
    }
}
