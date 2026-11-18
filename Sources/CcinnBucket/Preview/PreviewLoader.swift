import AppKit
import CcinnBucketKit
import Decompression
import Foundation
import PDFKit
import StorageKit

/// Text (plain, JSON, or decompressed gzip/Zstandard) shown in a preview.
struct TextPreview: Sendable {
    /// What is displayed: JSON indented, and lines longer than `TextLines.displayLimit` cut (a text view would hang
    /// laying out a multi-megabyte line).
    var displayText: String
    /// Lines cut in `displayText`.
    var linesCut: Int
    /// The text as stored (Raw view, Copy All).
    var rawText: String
    /// `rawText` has no line too long to show as it is.
    var rawIsViewable: Bool
    /// Length of the longest stored line (UTF-8 bytes).
    var longestLine: Int
    /// What editing starts from: the stored text, or — for minified JSON, whose single line is too long to edit — its
    /// indented form, compacted again on save (`compactsOnSave`). `nil` when no form can be edited safely.
    var editableText: String?
    var compactsOnSave: Bool
    /// `rawText` is exactly the object's bytes (valid UTF-8, nothing replaced), so saving an edit changes only the
    /// characters the user changed.
    var isExact: Bool
    var isJSON: Bool
    /// The whole object was read and decoded.
    var isComplete: Bool
    /// Decoded bytes shown.
    var shownBytes: Int64
    var progress: PreviewProgress
    var compression: CompressionFormat?
    /// ETag of the version shown (an edit is saved only if the object still has it).
    var eTag: String?
    /// Why re-compressing this object would lose part of it (BGZF extra fields, seekable zstd), or `nil`.
    var structureWarning: String?
}

enum PreviewContent {
    case idle
    /// Loading; with progress once the first bytes arrive.
    case loading(PreviewProgress?)
    case text(TextPreview)
    /// Binary content: a hex dump of the beginning.
    case binary(String, note: String)
    case image(NSImage)
    case pdf(PDFDocument)
    case file(URL)
    case unavailable(String)
}

/// How much a preview reads.
enum PreviewBudget {
    /// The inspector: a quick look at the beginning.
    case inspector
    /// The preview window: more, with Show More.
    case window

    /// Decoded bytes loaded at first.
    var initialBytes: Int {
        switch self {
        case .inspector: 64 << 10
        case .window: 8 << 20
        }
    }

    /// Each Show More adds this much.
    static let stepBytes = 8 << 20
    /// The preview window never holds more than this.
    static let maximumBytes = 64 << 20
}

/// Loads previews: text, JSON and compressed objects stream from the start with progress (`PreviewStream`), images
/// and PDFs load bounded in memory, other types download to a temporary file for QuickLook with progress.
enum PreviewLoader {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CcinnBucket-Previews", isDirectory: true)

    static func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    /// Content plus, for streamed text, the stream to continue with Show More.
    struct Loaded {
        var content: PreviewContent
        var stream: PreviewStream?
        var plan: PreviewPlan
    }

    static func load(bucket: String, key: String, versionID: String?, contentType: String?, size: Int64, storage: any ObjectStorage,
                     budget: PreviewBudget, progress: @escaping @MainActor @Sendable (PreviewProgress) -> Void) async -> Loaded {
        let plan = PreviewPlan.make(key: key, contentType: contentType, size: size)
        do {
            switch plan.kind {
            case .empty:
                return Loaded(content: .unavailable(key.hasSuffix("/") ? "Folder marker" : "Empty object"), plan: plan)
            case .tooLarge:
                return Loaded(content: .unavailable("Too large to preview (\(SizeFormat.bytes(size))). Download it instead."), plan: plan)
            case .text, .json, .compressed:
                let stream = PreviewStream(storage: storage, bucket: bucket, key: key, versionID: versionID, size: size,
                                           compression: plan.compression)
                let content = try await loadText(stream, upTo: budget.initialBytes, isJSON: plan.isJSON, progress: progress)
                return Loaded(content: content, stream: stream, plan: plan)
            case .image:
                let data = try await storage.getObject(bucket: bucket, key: key, versionID: versionID, range: nil, maxBytes: Int(PreviewPlan.imageLimit) + 1)
                if let image = NSImage(data: data.data) { return Loaded(content: .image(image), plan: plan) }
                return Loaded(content: try await quickLookFile(bucket: bucket, key: key, versionID: versionID, size: size, storage: storage,
                                                               progress: progress), plan: plan)
            case .pdf:
                let data = try await storage.getObject(bucket: bucket, key: key, versionID: versionID, range: nil, maxBytes: Int(PreviewPlan.documentLimit) + 1)
                if let document = PDFDocument(data: data.data) { return Loaded(content: .pdf(document), plan: plan) }
                return Loaded(content: .unavailable("The PDF could not be opened."), plan: plan)
            case .quickLook:
                return Loaded(content: try await quickLookFile(bucket: bucket, key: key, versionID: versionID, size: size, storage: storage,
                                                               progress: progress), plan: plan)
            }
        } catch {
            return Loaded(content: failure(error), plan: plan)
        }
    }

    /// Reads more of a streamed text preview (Show More).
    static func loadText(_ stream: PreviewStream, upTo limit: Int, isJSON: Bool,
                         progress: @escaping @MainActor @Sendable (PreviewProgress) -> Void) async throws -> PreviewContent {
        let snapshot = try await stream.load(upTo: limit) { value in Task { @MainActor in progress(value) } }
        // Formatting a few MB of text is real work: keep it off the main actor.
        switch await Task.detached(priority: .userInitiated, operation: { decodedText(snapshot, isJSON: isJSON) }).value {
        case let .text(preview): return .text(preview)
        case let .binary(dump, note): return .binary(dump, note: note)
        }
    }

    /// The `Sendable` part of `PreviewContent` that text decoding produces.
    enum DecodedText: Sendable {
        case text(TextPreview)
        case binary(String, note: String)
    }

    nonisolated static func decodedText(_ snapshot: PreviewSnapshot, isJSON: Bool) -> DecodedText {
        let data = snapshot.data
        if TextSniffer.isLikelyBinary(data) {
            let what = snapshot.progress.compression.map { "Decompressed \($0.displayName) content is binary" } ?? "Binary content"
            return .binary(HexDump.format(data, limit: 64 << 10), note: "\(what); showing the first 64 KB as hex.")
        }
        let exact = TextSniffer.strictUTF8(data)
        let raw = exact ?? TextSniffer.displayText(data)
        let formatted = isJSON ? JSONIndenter.format(raw) : raw
        let longest = TextLines.longestLine(raw)
        let (display, linesCut) = TextLines.cuttingLongLines(formatted)
        var editable: String?
        var compacts = false
        if longest <= TextLines.displayLimit {
            editable = raw
        } else if isJSON, TextLines.longestLine(formatted) <= TextLines.displayLimit, JSONIndenter.compact(raw) == raw {
            // Minified JSON: edit it indented; saving compacts it again, so only the edited tokens change.
            editable = formatted
            compacts = true
        }
        var structureWarning: String?
        if snapshot.objectType?.lowercased() == "appendable" {
            structureWarning = "This is an appendable object; saving would turn it into a normal object and later appends would fail."
        } else if let container = snapshot.container {
            if container.hasExtraField {
                structureWarning = "This gzip file has extra header fields (as BGZF/tabix indexes use); saving would rewrite it as plain gzip."
            } else if snapshot.progress.compression == .zstd, container.units > 1 || container.skippableFrames > 0 {
                structureWarning = "This Zstandard file has several frames or a seek table; saving would rewrite it as one frame."
            }
        }
        return .text(TextPreview(displayText: display, linesCut: linesCut, rawText: raw, rawIsViewable: longest <= TextLines.displayLimit,
                                 longestLine: longest, editableText: editable, compactsOnSave: compacts, isExact: exact != nil,
                                 isJSON: isJSON, isComplete: snapshot.isComplete, shownBytes: Int64(data.count), progress: snapshot.progress,
                                 compression: snapshot.progress.compression, eTag: snapshot.eTag, structureWarning: structureWarning))
    }

    static func failure(_ error: any Error) -> PreviewContent {
        if error is CancellationError { return .idle }
        if let decompression = error as? DecompressionError { return .unavailable(decompression.description) }
        if let changed = error as? PreviewStream.StreamError { return .unavailable(changed.localizedDescription) }
        let wrapped = StorageError.wrap(error)
        return wrapped.isCancellation ? .idle : .unavailable(wrapped.description)
    }

    private static func quickLookFile(bucket: String, key: String, versionID: String?, size: Int64, storage: any ObjectStorage,
                                      progress: @escaping @MainActor @Sendable (PreviewProgress) -> Void) async throws -> PreviewContent {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard let destination = LocalPathMapper.localURL(forKey: ObjectPath.lastComponent(of: key), relativeTo: "", root: folder) else {
            return .unavailable("This object cannot be previewed.")
        }
        let counter = ByteCounter()
        try await ObjectDownloader(storage: storage, limiter: AsyncLimiter(limit: 4)).download(bucket: bucket, key: key, versionID: versionID,
                                                                                              to: destination) { bytes in
            let received = counter.add(bytes)
            Task { @MainActor in
                progress(PreviewProgress(receivedBytes: received, totalBytes: size, decodedBytes: received, compression: nil))
            }
        }
        return .file(destination)
    }
}

/// Thread-safe running total for download progress callbacks.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0

    func add(_ bytes: Int64) -> Int64 {
        lock.withLock {
            total &+= max(0, bytes)
            return total
        }
    }
}
