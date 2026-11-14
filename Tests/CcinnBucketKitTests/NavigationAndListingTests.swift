import CcinnBucketKit
import Foundation
import StorageKit
import Testing

@Suite("Prefix navigation and listing rows")
struct NavigationAndListingTests {
    @Test("breadcrumbs, parents and display names")
    func paths() {
        #expect(ObjectPath.breadcrumbs(prefix: "photos/2024/june/").map(\.title) == ["photos", "2024", "june"])
        #expect(ObjectPath.breadcrumbs(prefix: "photos/2024/june/").map(\.prefix) == ["photos/", "photos/2024/", "photos/2024/june/"])
        #expect(ObjectPath.breadcrumbs(prefix: "").isEmpty)
        #expect(ObjectPath.breadcrumbs(prefix: "a//b/").map(\.title) == ["a", "", "b"])
        #expect(ObjectPath.parent(of: "photos/2024/") == "photos/")
        #expect(ObjectPath.parent(of: "photos/") == "")
        #expect(ObjectPath.parent(of: "") == nil)
        #expect(ObjectPath.parent(of: "a//") == "a/")
        #expect(ObjectPath.displayName(of: "photos/2024/IMG.jpg", in: "photos/2024/") == "IMG.jpg")
        #expect(ObjectPath.displayName(of: "photos/2024/", in: "photos/") == "2024")
        #expect(ObjectPath.displayName(of: "a//", in: "a/") == "(empty name)")
        #expect(ObjectPath.lastComponent(of: "x/y/z.txt") == "z.txt")
        #expect(ObjectPath.lastComponent(of: "x/y/") == "y")
        #expect(ObjectPath.fileExtension(of: "archive.TAR.GZ") == "gz")
        #expect(ObjectPath.fileExtension(of: "README") == nil)
        #expect(ObjectPath.fileExtension(of: ".bashrc") == nil)
    }

    @Test("history: visit, back, forward; visiting after back drops the forward stack")
    func history() {
        var history = NavigationHistory(start: BrowserLocation(bucket: "b", prefix: ""))
        history.visit(BrowserLocation(bucket: "b", prefix: "a/"))
        history.visit(BrowserLocation(bucket: "b", prefix: "a/b/"))
        #expect(history.canGoBack && !history.canGoForward)
        #expect(history.goBack()?.prefix == "a/")
        #expect(history.goBack()?.prefix == "")
        #expect(history.goBack() == nil)
        #expect(history.goForward()?.prefix == "a/")
        history.visit(BrowserLocation(bucket: "b", prefix: "c/"))
        #expect(!history.canGoForward)
        #expect(history.current.prefix == "c/")
        history.visit(BrowserLocation(bucket: "b", prefix: "c/"))
        #expect(history.goBack()?.prefix == "a/", "re-visiting the current location is not a new entry")
        for index in 0..<500 { history.visit(BrowserLocation(bucket: "b", prefix: "p\(index)/")) }
        var steps = 0
        while history.goBack() != nil { steps += 1 }
        #expect(steps <= NavigationHistory.limit)
    }

    @Test("pages merge into rows: folders first, markers for the current prefix hidden, no duplicates")
    func accumulate() {
        var listing = ListingAccumulator(prefix: "photos/")
        listing.append(ListPage(objects: [ObjectEntry(key: "photos/", size: 0), ObjectEntry(key: "photos/b.jpg", size: 10),
                                          ObjectEntry(key: "photos/2025/", size: 0)],
                                commonPrefixes: ["photos/2024/"], isTruncated: true, nextToken: .continuation("t"), apiVersion: .v2))
        listing.append(ListPage(objects: [ObjectEntry(key: "photos/a.jpg", size: 5)], commonPrefixes: ["photos/2025/"],
                                isTruncated: false, nextToken: nil, apiVersion: .v2))
        #expect(listing.rows.map(\.name) == ["2024", "2025", "b.jpg", "a.jpg"])
        #expect(listing.rows.filter(\.isFolder).count == 2)
        #expect(listing.objectCount == 2)
        #expect(listing.folderCount == 2)
        #expect(listing.totalBytes == 15)
        #expect(listing.isComplete)
    }

    @Test("sorting keeps folders first and is stable", arguments: ListingSortColumn.allCases)
    func sorting(_ column: ListingSortColumn) {
        let rows = [
            ListingRow.object(ObjectEntry(key: "p/b.txt", size: 30, lastModified: Date(timeIntervalSince1970: 3), storageClass: "STANDARD"), prefix: "p/"),
            ListingRow.folder("p/z/", prefix: "p/"),
            ListingRow.object(ObjectEntry(key: "p/A.jpg", size: 10, lastModified: Date(timeIntervalSince1970: 1), storageClass: "GLACIER"), prefix: "p/"),
            ListingRow.object(ObjectEntry(key: "p/c.TXT", size: 20, lastModified: nil, storageClass: nil), prefix: "p/"),
            ListingRow.folder("p/a/", prefix: "p/"),
        ]
        for ascending in [true, false] {
            let sorted = ListingSorter.sorted(rows, by: column, ascending: ascending)
            #expect(sorted.prefix(2).allSatisfy { $0.isFolder })
            #expect(sorted.count == rows.count)
        }
        if column == .name {
            #expect(ListingSorter.sorted(rows, by: .name, ascending: true).map(\.name) == ["a", "z", "A.jpg", "b.txt", "c.TXT"])
        }
        if column == .size {
            #expect(ListingSorter.sorted(rows, by: .size, ascending: false).map(\.name).suffix(3) == ["b.txt", "c.TXT", "A.jpg"])
        }
    }

    @Test("sorting 100,000 rows is fast enough to stay off the critical path")
    func sortingPerformance() {
        let rows = (0..<100_000).map { index in
            ListingRow.object(ObjectEntry(key: "bulk/obj-\(String(format: "%06d", (index * 7_919) % 100_000)).txt", size: Int64(index)), prefix: "bulk/")
        }
        let start = Date()
        let sorted = ListingSorter.sorted(rows, by: .name, ascending: true)
        #expect(sorted.first?.name == "obj-000000.txt")
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test("filter text becomes a server-side prefix within the folder")
    func prefixFilter() {
        #expect(ObjectPath.listingPrefix(folder: "photos/", filter: "IMG_20") == "photos/IMG_20")
        #expect(ObjectPath.listingPrefix(folder: "photos/", filter: "") == "photos/")
        #expect(ObjectPath.listingPrefix(folder: "", filter: "  logs") == "logs")
    }

    @Test("version rows group by key, newest first")
    func versionRows() {
        let versions = [
            ObjectVersion(key: "n/d.txt", versionID: "v3", isLatest: true, isDeleteMarker: true, lastModified: Date(timeIntervalSince1970: 3)),
            ObjectVersion(key: "n/d.txt", versionID: "v2", isLatest: false, isDeleteMarker: false, size: 6, lastModified: Date(timeIntervalSince1970: 2)),
            ObjectVersion(key: "n/a.txt", versionID: "v1", isLatest: true, isDeleteMarker: false, size: 1, lastModified: Date(timeIntervalSince1970: 1)),
        ]
        let rows = ListingRow.versionRows(versions, prefix: "n/")
        #expect(rows.map(\.name) == ["d.txt", "d.txt", "a.txt"])
        #expect(rows.first?.version?.isDeleteMarker == true)
    }
}

@Suite("Listing merge and download planning")
struct ListingMergeTests {
    @Test("merging sorted pages equals sorting everything", arguments: ListingSortColumn.allCases)
    func merge(_ column: ListingSortColumn) {
        var generator = SystemRandomNumberGenerator()
        func row(_ index: Int) -> ListingRow {
            index.isMultiple(of: 17) ? .folder("p/folder\(index)/", prefix: "p/")
                : .object(ObjectEntry(key: "p/File\(Int.random(in: 0..<500, using: &generator))-\(index).txt", size: Int64.random(in: 0..<100, using: &generator),
                                      lastModified: Date(timeIntervalSince1970: Double(Int.random(in: 0..<50, using: &generator))),
                                      storageClass: ["STANDARD", "GLACIER", nil].randomElement(using: &generator) ?? nil), prefix: "p/")
        }
        for ascending in [true, false] {
            let pages = (0..<5).map { page in (0..<300).map { row(page * 1_000 + $0) } }
            var merged: [ListingRow] = []
            for page in pages { merged = ListingSorter.merging(merged, with: page, by: column, ascending: ascending) }
            #expect(merged.map(\.id) == ListingSorter.sorted(pages.flatMap { $0 }, by: column, ascending: ascending).map(\.id))
        }
    }

    @Test("download plans keep case- and Unicode-variant keys apart")
    func downloadPlan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-plan-\(UUID().uuidString)")
        let items = DownloadPlanner.plan([.init(key: "docs/README.md", size: 1), .init(key: "docs/readme.md", size: 2),
                                          .init(key: "docs/café.txt".precomposedStringWithCanonicalMapping, size: 3),
                                          .init(key: "docs/café.txt".decomposedStringWithCanonicalMapping, size: 4), .init(key: "docs/sub/", size: 0)],
                                         bucket: "b", relativeTo: "", root: root)
        let destinations = items.compactMap { item -> String? in
            if case let .download(_, _, _, destination) = item.kind { return LocalPathMapper.reservationKey(destination) }
            return nil
        }
        #expect(destinations.count == 4)
        #expect(Set(destinations).count == 4)
    }
}
