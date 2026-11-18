import Foundation
import StorageKit

/// How the object browser presents a folder: a sortable list, or Finder-style columns for every folder on the path.
public enum BrowserViewStyle: String, CaseIterable, Sendable {
    case list
    case columns

    /// `UserDefaults` key of the style used when a browser opens.
    public static let defaultsKey = "browserViewStyle"

    /// The remembered style; anything missing or unknown is the list.
    public static func stored(in defaults: UserDefaults) -> BrowserViewStyle {
        defaults.string(forKey: defaultsKey).flatMap(BrowserViewStyle.init(rawValue:)) ?? .list
    }

    public func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

extension ObjectPath {
    /// Prefixes of the columns that show `prefix`: the bucket root, then every folder down to `prefix`.
    /// `a/b/` → ["", "a/", "a/b/"]. Empty segments (`a//`) are kept, as in breadcrumbs.
    public static func columnPrefixes(of prefix: String) -> [String] {
        [""] + breadcrumbs(prefix: prefix).map(\.prefix)
    }

    /// The folder highlighted in the column for `column` on the way to `prefix`: the next prefix on the path.
    /// `nil` for the deepest column and for columns that are not on the path.
    public static func highlightedChild(in column: String, toward prefix: String) -> String? {
        let columns = columnPrefixes(of: prefix)
        guard let index = columns.firstIndex(of: column), columns.indices.contains(index + 1) else { return nil }
        return columns[index + 1]
    }
}

/// What selecting rows in a column means (the same rule for clicks and arrow keys in every column).
public enum ColumnSelection {
    public struct Outcome: Equatable, Sendable {
        /// The folder that becomes current (the deepest column).
        public var folder: String
        /// Row ids selected in that folder.
        public var selection: Set<String>

        public init(folder: String, selection: Set<String>) {
            self.folder = folder
            self.selection = selection
        }
    }

    /// Exactly one folder opens it with nothing selected; anything else selects the rows in the column's own folder.
    public static func resolve(column: String, selected: [ListingRow]) -> Outcome {
        if selected.count == 1, let only = selected.first, only.isFolder {
            return Outcome(folder: only.key, selection: [])
        }
        return Outcome(folder: column, selection: Set(selected.map(\.id)))
    }
}

public enum ColumnMove: Sendable {
    case left
    case right
}

/// ← and → between columns.
public enum ColumnNavigator {
    public struct Plan: Equatable, Sendable {
        public enum Selection: Equatable, Sendable {
            /// Leave the current folder's selection as it is.
            case keep
            /// Nothing selected in the current folder.
            case clear
            /// Select the first row of the focused (deepest) column.
            case selectFirst
        }

        /// The current folder after the move.
        public var folder: String
        /// The column that receives keyboard focus.
        public var focus: String
        public var selection: Selection

        public init(folder: String, focus: String, selection: Selection) {
            self.folder = folder
            self.focus = focus
            self.selection = selection
        }
    }

    /// The move from the column for `column` while `current` is the current folder; `nil` when there is nowhere to go.
    public static func plan(_ move: ColumnMove, from column: String, current: String, currentHasSelection: Bool) -> Plan? {
        let columns = ObjectPath.columnPrefixes(of: current)
        guard let index = columns.firstIndex(of: column) else { return nil }
        switch move {
        case .left:
            guard index > 0 else { return nil }
            // The column's folder stays visible as the deepest column; its parent column highlights it.
            return Plan(folder: column, focus: columns[index - 1], selection: .clear)
        case .right:
            guard columns.indices.contains(index + 1) else { return nil }
            let next = columns[index + 1]
            let selectFirst = next == current && !currentHasSelection
            return Plan(folder: current, focus: next, selection: selectFirst ? .selectFirst : .keep)
        }
    }
}

/// Which folder listings the column view keeps, reuses and releases when the current folder changes.
public enum ColumnReconciliation {
    public struct Plan: Equatable, Sendable {
        /// Existing ancestor listings that stay.
        public var keep: [String]
        /// The previous current folder's listing (handed over by the browser) becomes this ancestor column.
        public var adoptHanded: String?
        /// Ancestor columns to list from the server.
        public var create: [String]
        /// Existing listings to cancel and release (sorted).
        public var drop: [String]
        /// The existing listing for the new current folder moves to the browser instead of being listed again.
        public var seedCurrent: Bool

        public init(keep: [String], adoptHanded: String?, create: [String], drop: [String], seedCurrent: Bool) {
            self.keep = keep
            self.adoptHanded = adoptHanded
            self.create = create
            self.drop = drop
            self.seedCurrent = seedCurrent
        }
    }

    /// - Parameters:
    ///   - existing: prefixes that have an ancestor listing now.
    ///   - current: the new current folder.
    ///   - handed: the previous current folder, when the browser can hand its listing over.
    public static func plan(existing: Set<String>, current: String, handed: String?) -> Plan {
        let ancestors = ObjectPath.columnPrefixes(of: current).dropLast()
        var keep: [String] = []
        var adopt: String?
        var create: [String] = []
        for ancestor in ancestors {
            if existing.contains(ancestor) {
                keep.append(ancestor)
            } else if ancestor == handed {
                adopt = ancestor
            } else {
                create.append(ancestor)
            }
        }
        let wanted = Set(ancestors).union([current])
        return Plan(keep: keep, adoptHanded: adopt, create: create, drop: existing.subtracting(wanted).sorted(),
                    seedCurrent: existing.contains(current))
    }
}

/// The listing of one column: pages merged into rows kept in the browser's sort order (folders first).
/// A value type, so merging and sorting can run off the main actor.
public struct FolderColumnState: Sendable {
    public private(set) var accumulator: ListingAccumulator
    public private(set) var rows: [ListingRow]
    public private(set) var sortColumn: ListingSortColumn
    public private(set) var sortAscending: Bool
    /// Pages appended (an adopted listing counts as loaded).
    public private(set) var pagesLoaded: Int

    public var prefix: String { accumulator.prefix }
    /// No page has been listed yet.
    public var needsFirstPage: Bool { pagesLoaded == 0 }
    /// Another page can be requested with `nextToken`.
    public var hasMore: Bool { accumulator.nextToken != nil }
    public var nextToken: ListToken? { accumulator.nextToken }

    public init(prefix: String, sortColumn: ListingSortColumn = .name, ascending: Bool = true) {
        accumulator = ListingAccumulator(prefix: prefix)
        rows = []
        self.sortColumn = sortColumn
        sortAscending = ascending
        pagesLoaded = 0
    }

    /// Adopts a listing that is already loaded; `sortedRows` must be `accumulator`'s rows in the given order.
    public init(accumulator: ListingAccumulator, sortedRows: [ListingRow], sortColumn: ListingSortColumn, ascending: Bool) {
        self.accumulator = accumulator
        rows = sortedRows
        self.sortColumn = sortColumn
        sortAscending = ascending
        pagesLoaded = 1
    }

    public mutating func append(_ page: ListPage) {
        let (folderCount, objectCount) = (accumulator.folderCount, accumulator.objectCount)
        accumulator.append(page)
        let incoming = Array(accumulator.folders.dropFirst(folderCount)) + Array(accumulator.objects.dropFirst(objectCount))
        rows = ListingSorter.merging(rows, with: incoming, by: sortColumn, ascending: sortAscending)
        pagesLoaded += 1
    }

    public mutating func resort(by column: ListingSortColumn, ascending: Bool) {
        guard column != sortColumn || ascending != sortAscending else { return }
        sortColumn = column
        sortAscending = ascending
        rows = ListingSorter.sorted(rows, by: column, ascending: ascending)
    }

    public func contains(id: String) -> Bool { rows.contains { $0.id == id } }

    /// Rows with these ids, in display order.
    public func rows(withIDs ids: Set<String>) -> [ListingRow] {
        ids.isEmpty ? [] : rows.filter { ids.contains($0.id) }
    }
}
