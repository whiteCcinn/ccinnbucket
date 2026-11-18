import CcinnBucketKit
import Foundation
import StorageKit
import Testing

@Suite("Column view: style, paths, selection, keyboard, reconciliation and column state")
struct ColumnViewTests {
    // MARK: Helpers

    private static func folder(_ key: String, in prefix: String) -> ListingRow { .folder(key, prefix: prefix) }

    private static func object(_ key: String, in prefix: String, size: Int64 = 1) -> ListingRow {
        .object(ObjectEntry(key: key, size: size), prefix: prefix)
    }

    private static func page(_ keys: [String], folders: [String] = [], next: String? = nil) -> ListPage {
        ListPage(objects: keys.map { ObjectEntry(key: $0, size: Int64($0.count)) }, commonPrefixes: folders,
                 isTruncated: next != nil, nextToken: next.map { .continuation($0) }, apiVersion: .v2)
    }

    // MARK: 1.1 Style and paths

    @Test("view style: stored value round trip, unknown and missing values fall back to the list")
    func viewStyle() throws {
        let suite = "ColumnViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BrowserViewStyle.stored(in: defaults) == .list)
        BrowserViewStyle.columns.store(in: defaults)
        #expect(BrowserViewStyle.stored(in: defaults) == .columns)
        #expect(defaults.string(forKey: BrowserViewStyle.defaultsKey) == "columns")
        defaults.set("gallery", forKey: BrowserViewStyle.defaultsKey)
        #expect(BrowserViewStyle.stored(in: defaults) == .list)
        defaults.set(42, forKey: BrowserViewStyle.defaultsKey)
        #expect(BrowserViewStyle.stored(in: defaults) == .list)
    }

    @Test("column prefixes: the root, then every folder on the path; empty segments are kept")
    func columnPrefixes() {
        #expect(ObjectPath.columnPrefixes(of: "") == [""])
        #expect(ObjectPath.columnPrefixes(of: "photos/") == ["", "photos/"])
        #expect(ObjectPath.columnPrefixes(of: "photos/2024/june/") == ["", "photos/", "photos/2024/", "photos/2024/june/"])
        #expect(ObjectPath.columnPrefixes(of: "a//b/") == ["", "a/", "a//", "a//b/"])
    }

    @Test("highlight: each ancestor column highlights the next folder on the path; the deepest and off-path columns none")
    func highlights() {
        #expect(ObjectPath.highlightedChild(in: "", toward: "a/b/") == "a/")
        #expect(ObjectPath.highlightedChild(in: "a/", toward: "a/b/") == "a/b/")
        #expect(ObjectPath.highlightedChild(in: "a/b/", toward: "a/b/") == nil)
        #expect(ObjectPath.highlightedChild(in: "x/", toward: "a/b/") == nil)
        #expect(ObjectPath.highlightedChild(in: "", toward: "") == nil)
        #expect(ObjectPath.highlightedChild(in: "a/", toward: "a//") == "a//")
    }

    // MARK: 1.2 Selection rule and keyboard

    @Test("selection: exactly one folder opens it with nothing selected")
    func selectFolder() {
        let outcome = ColumnSelection.resolve(column: "a/", selected: [Self.folder("a/b/", in: "a/")])
        #expect(outcome == ColumnSelection.Outcome(folder: "a/b/", selection: []))
    }

    @Test("selection: files, several items or nothing stay in the column's folder")
    func selectOther() {
        let file = Self.object("a/x.txt", in: "a/")
        let folder = Self.folder("a/b/", in: "a/")
        #expect(ColumnSelection.resolve(column: "a/", selected: [file]) == .init(folder: "a/", selection: ["a/x.txt"]))
        #expect(ColumnSelection.resolve(column: "a/", selected: [file, folder]) == .init(folder: "a/", selection: ["a/x.txt", "a/b/"]))
        #expect(ColumnSelection.resolve(column: "a/", selected: [folder, Self.folder("a/c/", in: "a/")])
            == .init(folder: "a/", selection: ["a/b/", "a/c/"]))
        #expect(ColumnSelection.resolve(column: "a/", selected: []) == .init(folder: "a/", selection: []))
    }

    @Test("←: the column's folder becomes current with nothing selected, focus moves to its parent; nothing left of the root")
    func moveLeft() {
        #expect(ColumnNavigator.plan(.left, from: "a/b/", current: "a/b/", currentHasSelection: true)
            == .init(folder: "a/b/", focus: "a/", selection: .clear))
        #expect(ColumnNavigator.plan(.left, from: "a/", current: "a/b/", currentHasSelection: false)
            == .init(folder: "a/", focus: "", selection: .clear))
        #expect(ColumnNavigator.plan(.left, from: "", current: "a/b/", currentHasSelection: false) == nil)
        #expect(ColumnNavigator.plan(.left, from: "x/", current: "a/b/", currentHasSelection: false) == nil, "not on the path")
    }

    @Test("→: focus moves one column right; entering the deepest column without a selection selects its first row")
    func moveRight() {
        #expect(ColumnNavigator.plan(.right, from: "a/", current: "a/b/", currentHasSelection: false)
            == .init(folder: "a/b/", focus: "a/b/", selection: .selectFirst))
        #expect(ColumnNavigator.plan(.right, from: "a/", current: "a/b/", currentHasSelection: true)
            == .init(folder: "a/b/", focus: "a/b/", selection: .keep))
        #expect(ColumnNavigator.plan(.right, from: "", current: "a/b/", currentHasSelection: false)
            == .init(folder: "a/b/", focus: "a/", selection: .keep), "the next column is an ancestor: its highlight stays")
        #expect(ColumnNavigator.plan(.right, from: "a/b/", current: "a/b/", currentHasSelection: false) == nil, "nothing right of the deepest")
        #expect(ColumnNavigator.plan(.right, from: "x/", current: "a/b/", currentHasSelection: false) == nil)
    }

    // MARK: 1.3 Reconciliation and column state

    @Test("reconcile: going down hands the old current listing to its column and creates nothing")
    func reconcileDown() {
        let plan = ColumnReconciliation.plan(existing: [""], current: "a/b/", handed: "a/")
        #expect(plan == .init(keep: [""], adoptHanded: "a/", create: [], drop: [], seedCurrent: false))
    }

    @Test("reconcile: going up adopts the existing column as the current listing and drops deeper ones")
    func reconcileUp() {
        let plan = ColumnReconciliation.plan(existing: ["", "a/", "a/b/"], current: "a/", handed: "a/b/c/")
        #expect(plan == .init(keep: [""], adoptHanded: nil, create: [], drop: ["a/b/"], seedCurrent: true))
    }

    @Test("reconcile: a jump elsewhere keeps the shared root, creates the missing columns and drops the rest")
    func reconcileJump() {
        let plan = ColumnReconciliation.plan(existing: ["", "a/"], current: "x/y/", handed: "a/b/")
        #expect(plan == .init(keep: [""], adoptHanded: nil, create: ["x/"], drop: ["a/"], seedCurrent: false))
        let first = ColumnReconciliation.plan(existing: [], current: "a/b/", handed: nil)
        #expect(first == .init(keep: [], adoptHanded: nil, create: ["", "a/"], drop: [], seedCurrent: false))
    }

    @Test("column state: pages merge sorted, folders first; paging token and loaded state follow the pages")
    func columnStatePaging() {
        var state = FolderColumnState(prefix: "p/")
        #expect(state.needsFirstPage && !state.hasMore && state.rows.isEmpty)
        state.append(Self.page(["p/zeta.txt", "p/beta.txt"], folders: ["p/b/"], next: "t1"))
        #expect(!state.needsFirstPage && state.hasMore)
        #expect(state.nextToken == .continuation("t1"))
        state.append(Self.page(["p/alpha.txt"], folders: ["p/a/"]))
        #expect(!state.hasMore)
        #expect(state.rows.map(\.name) == ["a", "b", "alpha.txt", "beta.txt", "zeta.txt"])
        #expect(state.rows(withIDs: ["p/a/", "p/beta.txt", "missing"]).map(\.name) == ["a", "beta.txt"])
        #expect(state.contains(id: "p/b/") && !state.contains(id: "p/c/"))
    }

    @Test("column state: resort keeps folders first; adopting a listing keeps its rows and paging token")
    func columnStateResortAndAdopt() {
        var state = FolderColumnState(prefix: "p/")
        state.append(Self.page(["p/s.txt", "p/longest.txt", "p/mid.txt"], folders: ["p/f/"]))
        state.resort(by: .size, ascending: false)
        #expect(state.rows.map(\.name) == ["f", "longest.txt", "mid.txt", "s.txt"])
        #expect(state.sortColumn == .size && !state.sortAscending)

        var accumulator = ListingAccumulator(prefix: "q/")
        accumulator.append(Self.page(["q/b.txt"], next: "t2"))
        var adopted = FolderColumnState(accumulator: accumulator, sortedRows: accumulator.rows, sortColumn: .name, ascending: true)
        #expect(adopted.prefix == "q/" && !adopted.needsFirstPage && adopted.nextToken == .continuation("t2"))
        adopted.append(Self.page(["q/a.txt"]))
        #expect(adopted.rows.map(\.name) == ["a.txt", "b.txt"])
        #expect(!adopted.hasMore)
    }
}
