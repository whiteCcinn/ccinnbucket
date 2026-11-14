import CcinnBucketKit
import Foundation
import os
import StorageKit
import Testing

@Suite("Transfer planning, paths and throughput")
struct TransferLogicTests {
    @Test("upload planner preserves folder structure, skips .DS_Store, hidden files and symlinks")
    func uploadPlanner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnbucket-plan-\(UUID().uuidString)")
        let site = root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: site.appendingPathComponent("css"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<h1>".utf8).write(to: site.appendingPathComponent("index.html"))
        try Data("body{}".utf8).write(to: site.appendingPathComponent("css/app.css"))
        try Data().write(to: site.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: site.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(at: site.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        let single = root.appendingPathComponent("café.txt".decomposedStringWithCanonicalMapping)
        try Data("c".utf8).write(to: single)

        let plan = try UploadPlanner.plan([site, single], destinationPrefix: "www/")
        #expect(plan.map(\.key).sorted() == ["www/café.txt", "www/site/css/app.css", "www/site/index.html"])
        #expect(plan.first { $0.key == "www/café.txt" }?.key.unicodeScalars.count == "www/café.txt".precomposedStringWithCanonicalMapping.unicodeScalars.count)
        #expect(plan.reduce(0) { $0 + $1.size } == 4 + 6 + 1)
        let withHidden = try UploadPlanner.plan([site], destinationPrefix: "", includeHidden: true)
        #expect(withHidden.map(\.key).sorted() == ["site/.env", "site/css/app.css", "site/index.html"])
    }

    @Test("download paths stay inside the destination for hostile keys", arguments: [
        ("x/../../.ssh/config", "x/_../_../.ssh/config"),
        ("/etc/passwd", "etc/passwd"),
        ("a/./b", "a/_./b"),
        ("dir//file", "dir/file"),
        ("we:ird\u{0}name", "we_ird_name"),
        ("photos/2024/IMG.jpg", "2024/IMG.jpg"),
    ])
    func localPaths(_ key: String, _ expected: String) throws {
        let root = URL(fileURLWithPath: "/tmp/ccinnbucket-dest", isDirectory: true)
        let url = try #require(LocalPathMapper.localURL(forKey: key, relativeTo: "photos/", root: root))
        #expect(url.path == root.appendingPathComponent(expected).path)
        #expect(url.standardizedFileURL.path.hasPrefix(root.path + "/"))
    }

    @Test("folder markers and empty keys produce no file; long components are shortened")
    func localPathEdgeCases() throws {
        let root = URL(fileURLWithPath: "/tmp/ccinnbucket-dest", isDirectory: true)
        #expect(LocalPathMapper.localURL(forKey: "photos/2024/", relativeTo: "photos/", root: root) == nil)
        #expect(LocalPathMapper.localURL(forKey: "", relativeTo: "", root: root) == nil)
        #expect(LocalPathMapper.localURL(forKey: "///", relativeTo: "", root: root) == nil)
        let long = String(repeating: "é", count: 300) + ".txt"
        let url = try #require(LocalPathMapper.localURL(forKey: long, relativeTo: "", root: root))
        #expect(url.lastPathComponent.decomposedStringWithCanonicalMapping.utf8.count <= 255)
        #expect(url.lastPathComponent.hasSuffix(".txt"))
    }

    @Test("throughput meter smooths rates and estimates remaining time")
    func throughput() {
        var meter = ThroughputMeter(halfLife: 1)
        let start = Date(timeIntervalSince1970: 1_000)
        meter.record(totalBytes: 0, at: start)
        for second in 1...10 { meter.record(totalBytes: Int64(second) * 10_000_000, at: start.addingTimeInterval(TimeInterval(second))) }
        #expect(abs(meter.bytesPerSecond - 10_000_000) < 500_000)
        #expect(meter.remainingTime(forRemaining: 50_000_000).map { abs($0 - 5) < 0.5 } == true)
        meter.record(totalBytes: 100_000_000, at: start.addingTimeInterval(10.01))
        meter.record(totalBytes: 50, at: start.addingTimeInterval(11))
        #expect(meter.bytesPerSecond >= 0, "rolled-back progress never yields a negative rate")
        var idle = ThroughputMeter()
        #expect(idle.remainingTime(forRemaining: 100) == nil)
        idle.record(totalBytes: 5, at: start)
        idle.record(totalBytes: 5, at: start)
        #expect(idle.bytesPerSecond == 0)
    }

    @Test("byte, rate and duration formatting")
    func formatting() {
        #expect(SizeFormat.bytes(0) == "Zero KB" || SizeFormat.bytes(0) == "0 bytes")
        #expect(SizeFormat.bytes(1_536) == ByteCountFormatter.string(fromByteCount: 1_536, countStyle: .file), "matches Finder")
        #expect(SizeFormat.bytes(-5) == SizeFormat.bytes(0))
        #expect(SizeFormat.rate(15_000_000).hasSuffix("/s"))
        #expect(SizeFormat.duration(59) == "59s")
        #expect(SizeFormat.duration(3_725) == "1h 2m")
        #expect(SizeFormat.duration(.infinity) == "—")
        #expect(SizeFormat.count(1_234_567) == 1_234_567.formatted())
    }

    @Test("preview plans respect size limits and content types")
    func previewPlans() {
        #expect(PreviewPlan.make(key: "a/log.txt", contentType: "text/plain", size: 2_000_000_000).kind == .text)
        #expect(PreviewPlan.make(key: "a/log.txt", contentType: nil, size: 2_000_000_000).range == ByteRange(first: 0, last: (1 << 20) - 1))
        #expect(PreviewPlan.make(key: "a/log.txt", contentType: nil, size: 2_000_000_000).isTruncated)
        #expect(PreviewPlan.make(key: "c.json", contentType: "application/json", size: 100).kind == .json)
        #expect(PreviewPlan.make(key: "c.json", contentType: nil, size: 20 << 20).kind == .text)
        #expect(PreviewPlan.make(key: "p.png", contentType: "image/png", size: 3_000_000).kind == .image)
        #expect(PreviewPlan.make(key: "p.png", contentType: "image/png", size: 300_000_000).kind == .tooLarge)
        #expect(PreviewPlan.make(key: "doc.pdf", contentType: "application/pdf", size: 10_000).kind == .pdf)
        #expect(PreviewPlan.make(key: "slides.key", contentType: "application/octet-stream", size: 10_000).kind == .quickLook)
        #expect(PreviewPlan.make(key: "blob.bin", contentType: "application/octet-stream", size: 0).kind == .empty)
        #expect(PreviewPlan.make(key: "photos/", contentType: nil, size: 0).kind == .empty)
        #expect(PreviewPlan.make(key: "x.raw", contentType: "application/octet-stream", size: 10).kind == .quickLook)
    }

    @Test("content types are guessed from extensions")
    func contentTypes() {
        #expect(ContentTypes.guess(forKey: "index.html").hasPrefix("text/html"))
        #expect(ContentTypes.guess(forKey: "photo.JPG") == "image/jpeg")
        #expect(ContentTypes.guess(forKey: "data.json") == "application/json")
        #expect(ContentTypes.guess(forKey: "noext") == "application/octet-stream")
    }

    @Test("presign expiry presets and bounds")
    func presignExpiry() {
        #expect(PresignExpiry.presets.map(\.seconds) == [300, 3_600, 43_200, 86_400, 604_800])
        #expect(PresignExpiry.validate(seconds: 0, maximum: 604_800) != nil)
        #expect(PresignExpiry.validate(seconds: 604_801, maximum: 604_800) != nil)
        #expect(PresignExpiry.validate(seconds: 3_600, maximum: 604_800) == nil)
    }

    @Test("rename and move destinations")
    func renamePlanning() {
        #expect(KeyRewrite.renamed(key: "a/b/old.txt", newName: "new.txt") == "a/b/new.txt")
        #expect(KeyRewrite.renamed(key: "a/folder/", newName: "renamed") == "a/renamed/")
        #expect(KeyRewrite.moved(key: "a/folder/x/y.txt", from: "a/folder/", to: "b/dest/") == "b/dest/x/y.txt")
        #expect(KeyRewrite.validateName("ok name.txt") == nil)
        #expect(KeyRewrite.validateName("") != nil)
        #expect(KeyRewrite.validateName("a/b") != nil)
        #expect(KeyRewrite.validateName("..") != nil)
        #expect(KeyRewrite.isInside("a/folder/x", folder: "a/folder/"))
        #expect(!KeyRewrite.isInside("a/folderx", folder: "a/folder/"))
    }
}
