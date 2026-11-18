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
        /// A new folder inside `parent` (the current folder, or a column's folder in column view).
        case newFolder(parent: String)
        case rename(ListingRow)
        case transfer(rows: [ListingRow], move: Bool)
        case presign(ListingRow)
        case preview(ListingRow)

        var id: String {
            switch self {
            case let .newFolder(parent): "new-folder-" + parent
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

    /// A request for the table of the column `prefix` to take keyboard focus (a new nonce each time).
    struct ColumnFocus: Equatable {
        var prefix: String
        var nonce: Int
    }

    /// Navigation that comes from selecting in a column waits this long before listing, so holding ↓ through
    /// folders sends one request for the folder the user stops on instead of one per folder.
    static let columnListingDelay: UInt64 = 150_000_000

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
    /// List or columns, as chosen by the user (`effectiveViewStyle` is what is shown).
    private(set) var viewStyle: BrowserViewStyle
    /// The folders above the current one, in column view.
    let columns = FolderColumns()
    private(set) var columnFocus = ColumnFocus(prefix: "", nonce: 0)
    /// The sort order changed and `rows` are not re-sorted yet.
    private var isSorting = false

    private var loadTask: Task<Void, Never>?
    private var sortTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var busyTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    /// Rows received but not yet merged into `rows` (presentation is throttled while loading everything).
    private var pendingRows: [ListingRow] = []
    private var lastPresented = Date.distantPast

    /// Folder operations refuse to enumerate more keys than this (memory and safety bound).
    static let enumerationLimit = 1_000_000

    init(bucket: String, prefix: String, workspace: WorkspaceModel) {
        self.bucket = bucket
        storage = workspace.storage
        self.workspace = workspace
        history = NavigationHistory(start: BrowserLocation(bucket: bucket, prefix: prefix))
        accumulator = ListingAccumulator(prefix: prefix)
        viewStyle = BrowserViewStyle.stored(in: .standard)
    }

    var prefix: String { history.current.prefix }
    var isReadOnly: Bool { workspace?.isReadOnly ?? true }
    var breadcrumbs: [ObjectPath.Crumb] { ObjectPath.breadcrumbs(prefix: prefix) }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var canGoUp: Bool { ObjectPath.parent(of: prefix) != nil }
    var selectedRows: [ListingRow] { selection.isEmpty ? [] : rows.filter { selection.contains($0.id) } }
    var folderCount: Int { mode == .objects ? accumulator.folderCount : versionFolders.count }
    var objectCount: Int { mode == .objects ? accumulator.objectCount : versionItems.count }
    var loadedBytes: Int64 { mode == .objects ? accumulator.totalBytes : versionItems.reduce(0) { $0 &+ $1.size } }

    /// What is shown: versions always use the list.
    var effectiveViewStyle: BrowserViewStyle { mode == .versions ? .list : viewStyle }
    var isColumnView: Bool { effectiveViewStyle == .columns }
    /// The folders shown as columns, root first; the last one is the current folder.
    var columnPrefixes: [String] { isColumnView ? ObjectPath.columnPrefixes(of: prefix) : [prefix] }

    /// What the toolbar and the Object menu act on: the selection; in column view with nothing selected, the current
    /// folder, which is the row highlighted in its parent column (as in Finder).
    var actionRows: [ListingRow] {
        let selected = selectedRows
        guard selected.isEmpty, isColumnView, let parent = ObjectPath.parent(of: prefix) else { return selected }
        return [ListingRow.folder(prefix, prefix: parent)]
    }

    func setViewStyle(_ style: BrowserViewStyle, remember: Bool = true) {
        if remember { style.store(in: .standard) }
        guard style != viewStyle else { return }
        viewStyle = style
        syncColumns(handed: nil)
    }

    // MARK: Navigation

    func navigate(to prefix: String) {
        visit(prefix)
    }

    func goBack() {
        changeLocation { $0.goBack() != nil }
    }

    func goForward() {
        changeLocation { $0.goForward() != nil }
    }

    func goUp() {
        guard let parent = ObjectPath.parent(of: prefix) else { return }
        navigate(to: parent)
    }

    private func visit(_ folder: String, listingDelay: UInt64 = 0) {
        guard folder != prefix else { return }
        let location = BrowserLocation(bucket: bucket, prefix: folder)
        changeLocation(listingDelay: listingDelay) { history in
            history.visit(location)
            return true
        }
    }

    /// Moves in the history, hands the old listing to its column (column view) and lists the new folder, or adopts
    /// its column's listing when it already has one.
    private func changeLocation(listingDelay: UInt64 = 0, _ move: (inout NavigationHistory) -> Bool) {
        let previous = prefix
        let handed = isColumnView ? columnState() : nil
        guard move(&history), prefix != previous else { return }
        if !filterText.isEmpty {
            filterText = ""
            filterTask?.cancel() // after the assignment, which scheduled a reload
        }
        selection = []
        let seed = syncColumns(handed: handed)
        reloadListing(seed: seed, delay: seed == nil ? listingDelay : 0)
    }

    // MARK: Column view

    /// The current folder's listing as a column, when it is complete enough to reuse (objects, unfiltered, settled).
    private func columnState() -> FolderColumnState? {
        // No page in flight and rows in step with the accumulator: a merge still running in the background would
        // otherwise leave the handed-over column without that page for good.
        guard mode == .objects, filterText.isEmpty, !isLoading, !isLoadingMore, !isLoadingAll, !isSorting, error == nil, pendingRows.isEmpty,
              rows.count == accumulator.folderCount + accumulator.objectCount else { return nil }
        return FolderColumnState(accumulator: accumulator, sortedRows: rows, sortColumn: sortColumn, ascending: sortAscending)
    }

    /// Updates the ancestor columns for the current folder (or drops them outside column view).
    @discardableResult
    private func syncColumns(handed: FolderColumnState?) -> FolderColumnState? {
        guard isColumnView else {
            columns.removeAll()
            return nil
        }
        return columns.sync(current: prefix, handed: handed, bucket: bucket, storage: storage, sortColumn: sortColumn, ascending: sortAscending)
    }

    /// Selection in the column for `column` (clicks and ↑/↓): one folder opens it, anything else selects in that folder.
    func selectInColumn(_ column: String, ids: Set<String>) {
        guard isColumnView else {
            if selection != ids { selection = ids }
            return
        }
        let selected: [ListingRow]
        if column == prefix {
            selected = ids.isEmpty ? [] : rows.filter { ids.contains($0.id) }
        } else if let listing = columns.listing(for: column) {
            selected = listing.state.rows(withIDs: ids)
        } else {
            return
        }
        // Ids the column cannot resolve (its listing was replaced meanwhile) must not be read as "nothing selected",
        // which would navigate back to the column's folder.
        guard selected.count == ids.count else { return }
        let outcome = ColumnSelection.resolve(column: column, selected: selected)
        visit(outcome.folder, listingDelay: Self.columnListingDelay)
        if selection != outcome.selection { selection = outcome.selection }
    }

    /// ← and → between columns.
    func moveColumnFocus(_ move: ColumnMove, from column: String) {
        guard isColumnView,
              let plan = ColumnNavigator.plan(move, from: column, current: prefix, currentHasSelection: !selection.isEmpty) else { return }
        visit(plan.folder)
        switch plan.selection {
        case .keep:
            break
        case .clear:
            if !selection.isEmpty { selection = [] }
        case .selectFirst:
            if let first = rows.first { selectInColumn(prefix, ids: [first.id]) }
        }
        columnFocus = ColumnFocus(prefix: plan.focus, nonce: columnFocus.nonce &+ 1)
    }

    /// The focus request for the table of the column `column` (0 when it has none).
    func focusRequest(for column: String) -> Int {
        columnFocus.prefix == column ? columnFocus.nonce : 0
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
        syncColumns(handed: nil)
        reloadListing()
    }

    // MARK: Listing

    func cancelWork() {
        loadTask?.cancel()
        sortTask?.cancel()
        filterTask?.cancel()
        busyTask?.cancel()
        refreshTask?.cancel()
        inspector?.cancel()
        columns.removeAll()
    }

    /// Lists the current folder again, and every other column in column view (Refresh, finished transfers, …).
    func reload() {
        if isColumnView { columns.refreshAll() }
        syncColumns(handed: nil)
        reloadListing()
    }

    /// Lists the current folder from the first page, or adopts `seed` (a loaded column of this folder) without a request.
    /// - Parameter delay: nanoseconds to wait before the first request (cancelled by a newer listing).
    private func reloadListing(seed: FolderColumnState? = nil, delay: UInt64 = 0) {
        loadTask?.cancel()
        sortTask?.cancel()
        isSorting = false
        generation += 1
        let current = generation
        versionFolders = []
        versionItems = []
        versionMarker = (nil, nil)
        isLoadingAll = false
        isLoadingMore = false
        error = nil
        pendingRows = []
        // Adopt only a listing already in the current order (re-sorting a large one here would block the main actor).
        if let seed, mode == .objects, filterText.isEmpty, seed.prefix == prefix, seed.sortColumn == sortColumn,
           seed.sortAscending == sortAscending {
            accumulator = seed.accumulator
            hasMore = seed.hasMore
            isLoading = false
            applyRows(seed.rows, keepSelection: true)
            return
        }
        accumulator = ListingAccumulator(prefix: prefix)
        hasMore = false
        isLoading = true
        applyRows([], keepSelection: true)
        loadTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.loadNextPage(generation: current)
            // An older listing that was cancelled must not end the loading state of the newer one.
            if self?.generation == current { self?.isLoading = false }
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
            self?.reloadListing()
        }
    }

    func loadMoreIfNeeded() {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        let current = generation
        loadTask = Task { [weak self] in
            await self?.loadNextPage(generation: current)
            if self?.generation == current { self?.isLoadingMore = false }
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
            // A newer listing owns the loading flags; clearing them would let two page loads run at once.
            guard let self, self.generation == current else { return }
            self.isLoadingAll = false
            self.isLoadingMore = false
            await self.flushPending(generation: current)
        }
    }

    func stopLoadingAll() {
        loadTask?.cancel()
        isLoadingAll = false
        isLoadingMore = false
        let current = generation
        Task { [weak self] in await self?.flushPending(generation: current) }
    }

    private func flushPending(generation current: Int) async {
        guard !pendingRows.isEmpty, current == generation else { return }
        await present([], generation: current)
    }

    private func loadNextPage(generation current: Int) async {
        let listingPrefix = ObjectPath.listingPrefix(folder: prefix, filter: filterText)
        do {
            switch mode {
            case .objects:
                let token = accumulator.nextToken
                let page = try await storage.listObjects(ListObjectsRequest(bucket: bucket, prefix: listingPrefix, token: token))
                guard current == generation, !Task.isCancelled else { return }
                let (folderCount, objectCount) = (accumulator.folderCount, accumulator.objectCount)
                accumulator.append(page)
                hasMore = !accumulator.isComplete
                await present(Array(accumulator.folders.dropFirst(folderCount)) + Array(accumulator.objects.dropFirst(objectCount)), generation: current)
            case .versions:
                let page = try await storage.listObjectVersions(VersionListRequest(bucket: bucket, prefix: listingPrefix, keyMarker: versionMarker.key,
                                                                                    versionIDMarker: versionMarker.version))
                guard current == generation, !Task.isCancelled else { return }
                let known = Set(versionFolders.map(\.key))
                let newFolders = page.commonPrefixes.filter { !known.contains($0) }.map { ListingRow.folder($0, prefix: prefix) }
                let newItems = ListingRow.versionRows(page.versions, prefix: prefix)
                versionFolders += newFolders
                versionItems += newItems
                let nextMarker = (page.nextKeyMarker, page.nextVersionIDMarker)
                hasMore = page.isTruncated && (nextMarker.0 != nil || nextMarker.1 != nil) && (nextMarker.0 != versionMarker.key || nextMarker.1 != versionMarker.version)
                versionMarker = nextMarker
                await present(newFolders + newItems, generation: current)
            }
        } catch {
            guard current == generation else { return }
            let wrapped = StorageError.wrap(error)
            if !wrapped.isCancellation { self.error = wrapped.description }
            hasMore = false
        }
    }

    /// Merges newly listed rows into the sorted rows (off the main actor for large listings) and publishes them.
    /// While "Load All" runs, presentation is throttled so a million keys never cause quadratic main-thread work.
    private func present(_ newRows: [ListingRow], generation current: Int) async {
        pendingRows += newRows
        if isLoadingAll, hasMore, Date().timeIntervalSince(lastPresented) < 0.75 { return }
        let incoming = pendingRows
        pendingRows = []
        let existing = rows
        let column = sortColumn
        let ascending = sortAscending
        let merged: [ListingRow]
        if mode == .versions && column == .name && ascending {
            // Server order (key, newest version first), folders first.
            merged = existing.filter(\.isFolder) + incoming.filter(\.isFolder) + existing.filter { !$0.isFolder } + incoming.filter { !$0.isFolder }
        } else if existing.count + incoming.count > 3_000 {
            merged = await Task.detached(priority: .userInitiated) {
                ListingSorter.merging(existing, with: incoming, by: column, ascending: ascending)
            }.value
        } else {
            merged = ListingSorter.merging(existing, with: incoming, by: column, ascending: ascending)
        }
        guard current == generation else { return }
        lastPresented = Date()
        applyRows(merged, keepSelection: true)
    }

    /// Re-sorts everything after the sort order changed.
    private func resort(generation current: Int) async {
        let all = rows + pendingRows
        pendingRows = []
        let column = sortColumn
        let ascending = sortAscending
        let sorted: [ListingRow]
        if mode == .versions && column == .name && ascending {
            let unsorted = versionFolders + versionItems
            sorted = unsorted.filter(\.isFolder) + unsorted.filter { !$0.isFolder }
        } else {
            sorted = await Task.detached(priority: .userInitiated) { ListingSorter.sorted(all, by: column, ascending: ascending) }.value
        }
        // A newer sort cancels this one; the detached sort still finishes, so check before applying.
        guard current == generation, !Task.isCancelled else { return }
        isSorting = false
        applyRows(sorted, keepSelection: true)
    }

    func setSort(_ column: ListingSortColumn, ascending: Bool) {
        guard column != sortColumn || ascending != sortAscending else { return }
        sortColumn = column
        sortAscending = ascending
        isSorting = true
        let current = generation
        sortTask?.cancel()
        sortTask = Task { [weak self] in await self?.resort(generation: current) }
        columns.resort(by: column, ascending: ascending)
    }

    private func applyRows(_ newRows: [ListingRow], keepSelection: Bool) {
        rows = newRows
        rowsRevision = ListingRevision.next()
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
        guard let row = rows.first(where: { $0.key == key || $0.key == key + "/" }) else { return }
        selectInColumn(prefix, ids: [row.id])
    }

    // MARK: Operations — helpers

    private func toast(_ message: String, isError: Bool = false) { workspace?.showToast(message, isError: isError) }

    /// A short message at the bottom of the window (used by the preview window after saving).
    func showToast(_ message: String, isError: Bool = false) { toast(message, isError: isError) }

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
            let next = page.isTruncated ? page.nextToken : nil
            guard next != token else { throw StorageError.invalidResponse("The server returned the same listing page twice.") }
            token = next
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
            var sources: [DownloadPlanner.Source] = []
            for row in rows {
                let versionID = row.kind == .version ? row.version?.versionID : nil
                for object in try await self.expand([row]) {
                    sources.append(DownloadPlanner.Source(key: object.key, size: object.size, versionID: versionID))
                }
            }
            let bucket = self.bucket
            let prefix = self.prefix
            // Mapping and existence checks for up to a million objects run off the main actor.
            let items = await Task.detached(priority: .userInitiated) {
                DownloadPlanner.plan(sources, bucket: bucket, relativeTo: prefix, root: directory)
            }.value
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

    /// Creates `parent` + `name` + `/` (a zero-byte folder marker).
    func createFolder(named name: String, in parent: String) async -> String? {
        if let problem = KeyRewrite.validateName(name) { return problem }
        guard !refuseIfReadOnly() else { return StorageError.readOnly.message }
        let key = parent + name + "/"
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
        if move, rows.contains(where: { $0.kind == .version }) {
            toast("Versions can be copied or restored, not moved.", isError: true)
            return
        }
        if rows.contains(where: { $0.kind == .version }), rows.contains(where: { $0.kind != .version }) {
            toast("Select either versions or current objects, not both.", isError: true)
            return
        }
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
        let disposition = downloadName.map(ContentDisposition.attachment(filename:))
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
