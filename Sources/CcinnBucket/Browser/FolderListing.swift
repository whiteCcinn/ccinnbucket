import CcinnBucketKit
import Foundation
import Observation
import StorageKit

/// Revision numbers for listing contents, unique across every listing of the process. A table that switches from one
/// listing to another (a column that stops being the current folder) therefore always sees a new revision.
@MainActor
enum ListingRevision {
    private static var last = 0

    static func next() -> Int {
        last &+= 1
        return last
    }
}

/// One ancestor column of the column view: a paged, sorted listing of a folder (objects only, no filter) that shows
/// the folder highlighted on the path, loading a bounded number of extra pages to reach it.
@MainActor
@Observable
final class FolderListing {
    /// Pages a column lists on its own to reach its highlighted folder (1,000 keys each).
    static let revealPageLimit = 20
    /// Above this many rows, merging and sorting run off the main actor.
    static let backgroundThreshold = 3_000

    let bucket: String
    let prefix: String
    @ObservationIgnored private let storage: any ObjectStorage
    private(set) var state: FolderColumnState
    private(set) var revision = ListingRevision.next()
    private(set) var isLoading = false
    private(set) var error: String?
    /// The folder this column highlights (the next folder on the path).
    private(set) var highlight: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sortColumn: ListingSortColumn
    @ObservationIgnored private var sortAscending: Bool

    init(bucket: String, storage: any ObjectStorage, state: FolderColumnState, highlight: String?) {
        self.bucket = bucket
        prefix = state.prefix
        self.storage = storage
        self.state = state
        self.highlight = highlight
        sortColumn = state.sortColumn
        sortAscending = state.sortAscending
    }

    var rows: [ListingRow] { state.rows }
    var hasMore: Bool { state.hasMore }

    /// Lists the first page (or only reveals the highlight when the state was adopted already loaded).
    func start() {
        if state.needsFirstPage { refresh() } else { revealHighlight() }
    }

    /// Lists the folder again from the first page; the rows on screen stay until it arrives.
    func refresh() {
        run(from: FolderColumnState(prefix: prefix, sortColumn: sortColumn, ascending: sortAscending), maxPages: Self.revealPageLimit)
    }

    /// The next page, when the user scrolls near the end of the column.
    func loadMore() {
        guard state.hasMore, !isLoading else { return }
        run(from: state, maxPages: 1)
    }

    func setHighlight(_ key: String?) {
        guard key != highlight else { return }
        highlight = key
        revealHighlight()
    }

    func resort(by column: ListingSortColumn, ascending: Bool) {
        guard column != sortColumn || ascending != sortAscending else { return }
        sortColumn = column
        sortAscending = ascending
        if state.rows.count <= Self.backgroundThreshold {
            var sorted = state
            sorted.resort(by: column, ascending: ascending)
            publish(sorted)
            return
        }
        let snapshot = state
        let snapshotRevision = revision
        Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                var copy = snapshot
                copy.resort(by: column, ascending: ascending)
                return copy
            }.value
            // A page or refresh published meanwhile was already sorted the new way by `run`.
            guard let self, self.revision == snapshotRevision else { return }
            self.publish(sorted)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isLoading = false
    }

    // MARK: Loading

    private func revealHighlight() {
        guard let highlight, !isLoading, state.hasMore, !state.contains(id: highlight) else { return }
        run(from: state, maxPages: Self.revealPageLimit)
    }

    private func isSatisfied(_ candidate: FolderColumnState) -> Bool {
        guard let highlight else { return true }
        return candidate.contains(id: highlight)
    }

    /// Lists pages after `base` until the highlight is listed, the folder ends or `maxPages` pages were read;
    /// publishes after every page. A newer run or `cancel()` makes an older run's results disappear.
    private func run(from base: FolderColumnState, maxPages: Int) {
        task?.cancel()
        generation += 1
        let current = generation
        isLoading = true
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            var working = base
            var pages = 0
            do {
                repeat {
                    let request = ListObjectsRequest(bucket: self.bucket, prefix: self.prefix, token: working.nextToken)
                    let page = try await self.storage.listObjects(request)
                    guard current == self.generation, !Task.isCancelled else { return }
                    working = await self.appending(page, to: working)
                    guard current == self.generation, !Task.isCancelled else { return }
                    pages += 1
                    self.publish(working)
                } while working.hasMore && pages < maxPages && !self.isSatisfied(working)
            } catch {
                guard current == self.generation else { return }
                let wrapped = StorageError.wrap(error)
                if !wrapped.isCancellation { self.error = wrapped.description }
            }
            if current == self.generation { self.isLoading = false }
        }
    }

    /// Appends a page in the column's current sort order (off the main actor for large columns).
    private func appending(_ page: ListPage, to base: FolderColumnState) async -> FolderColumnState {
        let (column, ascending) = (sortColumn, sortAscending)
        let work: @Sendable () -> FolderColumnState = {
            var next = base
            next.resort(by: column, ascending: ascending)
            next.append(page)
            return next
        }
        if base.rows.count + page.objects.count + page.commonPrefixes.count <= Self.backgroundThreshold { return work() }
        return await Task.detached(priority: .userInitiated, operation: work).value
    }

    private func publish(_ next: FolderColumnState) {
        state = next
        revision = ListingRevision.next()
    }
}

/// The ancestor columns of a column view: one `FolderListing` for every folder on the path above the current one.
/// Listings follow the path (`ColumnReconciliation`): kept while on it, handed over or adopted when the current
/// folder moves up or down, cancelled and released when they leave it.
@MainActor
@Observable
final class FolderColumns {
    private(set) var listings: [String: FolderListing] = [:]

    func listing(for prefix: String) -> FolderListing? { listings[prefix] }

    /// Updates the columns for the current folder `current`.
    /// - Parameter handed: the previous current folder's listing, when the browser can hand it over.
    /// - Returns: the state of an already loaded column for `current`, for the browser to adopt instead of listing again.
    func sync(current: String, handed: FolderColumnState?, bucket: String, storage: any ObjectStorage,
              sortColumn: ListingSortColumn, ascending: Bool) -> FolderColumnState? {
        let plan = ColumnReconciliation.plan(existing: Set(listings.keys), current: current, handed: handed?.prefix)
        var seed: FolderColumnState?
        if plan.seedCurrent, let listing = listings.removeValue(forKey: current) {
            listing.cancel()
            // A refresh in flight would hand over the rows from before it; such a column is listed again instead.
            if !listing.state.needsFirstPage, listing.error == nil, !listing.isLoading { seed = listing.state }
        }
        for prefix in plan.drop {
            listings.removeValue(forKey: prefix)?.cancel()
        }
        var started: [FolderListing] = []
        if let prefix = plan.adoptHanded, var state = handed {
            state.resort(by: sortColumn, ascending: ascending)
            let listing = FolderListing(bucket: bucket, storage: storage, state: state,
                                        highlight: ObjectPath.highlightedChild(in: prefix, toward: current))
            listings[prefix] = listing
            started.append(listing)
        }
        for prefix in plan.create {
            let listing = FolderListing(bucket: bucket, storage: storage,
                                        state: FolderColumnState(prefix: prefix, sortColumn: sortColumn, ascending: ascending),
                                        highlight: ObjectPath.highlightedChild(in: prefix, toward: current))
            listings[prefix] = listing
            started.append(listing)
        }
        for prefix in plan.keep {
            listings[prefix]?.setHighlight(ObjectPath.highlightedChild(in: prefix, toward: current))
        }
        for listing in started { listing.start() }
        return seed
    }

    func resort(by column: ListingSortColumn, ascending: Bool) {
        for listing in listings.values { listing.resort(by: column, ascending: ascending) }
    }

    func refreshAll() {
        for listing in listings.values { listing.refresh() }
    }

    func removeAll() {
        guard !listings.isEmpty else { return }
        for listing in listings.values { listing.cancel() }
        listings = [:]
    }
}
