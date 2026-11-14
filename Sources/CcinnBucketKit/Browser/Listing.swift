import Foundation
import StorageKit

/// One row of the object table: a folder (common prefix or folder marker), an object, or an object version.
public struct ListingRow: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case folder
        case object
        case version
    }

    public var kind: Kind
    /// Full key (objects/versions) or prefix ending in `/` (folders).
    public var key: String
    public var name: String
    public var size: Int64
    public var lastModified: Date?
    public var storageClass: String?
    public var eTag: String?
    public var version: ObjectVersion?
    /// Lower-cased name, cached for fast sorting.
    let sortName: String

    public var id: String { version.map { $0.id } ?? key }
    public var isFolder: Bool { kind == .folder }

    init(kind: Kind, key: String, name: String, size: Int64, lastModified: Date?, storageClass: String?, eTag: String?, version: ObjectVersion?) {
        self.kind = kind
        self.key = key
        self.name = name
        self.size = size
        self.lastModified = lastModified
        self.storageClass = storageClass
        self.eTag = eTag
        self.version = version
        sortName = name.lowercased()
    }

    public static func folder(_ prefix: String, prefix parent: String) -> ListingRow {
        ListingRow(kind: .folder, key: prefix, name: ObjectPath.displayName(of: prefix, in: parent), size: 0, lastModified: nil,
                   storageClass: nil, eTag: nil, version: nil)
    }

    public static func object(_ entry: ObjectEntry, prefix: String) -> ListingRow {
        ListingRow(kind: .object, key: entry.key, name: ObjectPath.displayName(of: entry.key, in: prefix), size: entry.size,
                   lastModified: entry.lastModified, storageClass: entry.storageClass, eTag: entry.eTag, version: nil)
    }

    public static func versionRows(_ versions: [ObjectVersion], prefix: String) -> [ListingRow] {
        versions.map { version in
            ListingRow(kind: .version, key: version.key, name: ObjectPath.displayName(of: version.key, in: prefix), size: version.size,
                       lastModified: version.lastModified, storageClass: version.storageClass, eTag: version.eTag, version: version)
        }
    }

    /// File-type label for the Kind column ("Folder", "JPG", "Delete marker", …).
    public var typeLabel: String {
        switch kind {
        case .folder: return "Folder"
        case .version where version?.isDeleteMarker == true: return "Delete marker"
        default: return ObjectPath.fileExtension(of: key)?.uppercased() ?? "File"
        }
    }
}

/// Merges listing pages into rows for one folder: common prefixes and folder markers become folder rows
/// (deduplicated), the folder's own marker is hidden, and objects keep server order (lexicographic).
public struct ListingAccumulator: Sendable {
    public let prefix: String
    public private(set) var folders: [ListingRow] = []
    public private(set) var objects: [ListingRow] = []
    public private(set) var isComplete = false
    public private(set) var nextToken: ListToken?
    public private(set) var totalBytes: Int64 = 0
    private var knownFolders = Set<String>()

    public init(prefix: String) {
        self.prefix = prefix
    }

    public mutating func append(_ page: ListPage) {
        for commonPrefix in page.commonPrefixes where knownFolders.insert(commonPrefix).inserted {
            folders.append(.folder(commonPrefix, prefix: prefix))
        }
        for object in page.objects {
            if object.key == prefix, object.isFolderMarker { continue }
            if object.isFolderMarker, object.key.hasPrefix(prefix), !object.key.dropFirst(prefix.count).dropLast().contains("/") {
                if knownFolders.insert(object.key).inserted { folders.append(.folder(object.key, prefix: prefix)) }
                continue
            }
            objects.append(.object(object, prefix: prefix))
            totalBytes &+= max(0, object.size)
        }
        nextToken = page.isTruncated ? page.nextToken : nil
        isComplete = nextToken == nil
    }

    /// Folders first (sorted by name), then objects in server order.
    public var rows: [ListingRow] {
        folders.sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending } + objects
    }

    public var objectCount: Int { objects.count }
    public var folderCount: Int { folders.count }
}

public enum ListingSortColumn: String, CaseIterable, Sendable {
    case name
    case size
    case modified
    case storageClass
    case kind
}

public enum ListingSorter {
    /// The ordering used by the object table: folders first; ties broken by name, key, then newest version.
    public static func ordering(by column: ListingSortColumn, ascending: Bool) -> @Sendable (ListingRow, ListingRow) -> Bool {
        @Sendable func compareNames(_ lhs: ListingRow, _ rhs: ListingRow) -> ComparisonResult {
            if lhs.sortName != rhs.sortName { return lhs.sortName < rhs.sortName ? .orderedAscending : .orderedDescending }
            if lhs.key != rhs.key { return lhs.key < rhs.key ? .orderedAscending : .orderedDescending }
            return .orderedSame
        }
        @Sendable func compare(_ lhs: ListingRow, _ rhs: ListingRow) -> ComparisonResult {
            switch column {
            case .name:
                return compareNames(lhs, rhs)
            case .size:
                return lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            case .modified:
                let left = lhs.lastModified ?? .distantPast
                let right = rhs.lastModified ?? .distantPast
                return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            case .storageClass:
                return (lhs.storageClass ?? "").compare(rhs.storageClass ?? "")
            case .kind:
                return lhs.typeLabel.compare(rhs.typeLabel)
            }
        }
        return { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            var result = compare(lhs, rhs)
            if result == .orderedSame {
                result = compareNames(lhs, rhs)
                if result == .orderedSame, let left = lhs.version?.lastModified, let right = rhs.version?.lastModified, left != right {
                    return left > right
                }
                return result == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// Folders always first; ties keep a stable order by name then key.
    public static func sorted(_ rows: [ListingRow], by column: ListingSortColumn, ascending: Bool) -> [ListingRow] {
        rows.sorted(by: ordering(by: column, ascending: ascending))
    }

    /// Merges `newRows` into already sorted `sortedRows` in O(n + m log m) instead of re-sorting everything.
    public static func merging(_ sortedRows: [ListingRow], with newRows: [ListingRow], by column: ListingSortColumn, ascending: Bool) -> [ListingRow] {
        guard !newRows.isEmpty else { return sortedRows }
        let inOrder = ordering(by: column, ascending: ascending)
        let incoming = newRows.sorted(by: inOrder)
        guard !sortedRows.isEmpty else { return incoming }
        var result: [ListingRow] = []
        result.reserveCapacity(sortedRows.count + incoming.count)
        var left = 0
        var right = 0
        while left < sortedRows.count, right < incoming.count {
            if inOrder(incoming[right], sortedRows[left]) {
                result.append(incoming[right])
                right += 1
            } else {
                result.append(sortedRows[left])
                left += 1
            }
        }
        result.append(contentsOf: sortedRows[left...])
        result.append(contentsOf: incoming[right...])
        return result
    }
}
