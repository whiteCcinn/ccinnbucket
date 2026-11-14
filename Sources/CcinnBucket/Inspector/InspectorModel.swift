import AppKit
import CcinnBucketKit
import Foundation
import Observation
import PDFKit
import StorageKit

/// Editable copy of an object's writable metadata.
struct MetadataDraft: Equatable {
    struct Pair: Equatable, Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    var contentType: String
    var cacheControl: String
    var contentDisposition: String
    var contentEncoding: String
    var contentLanguage: String
    var storageClass: String
    var metadata: [Pair]
    var tags: [Pair]

    init(metadata: ObjectMetadata, tags: [ObjectTag], defaultStorageClass: String) {
        contentType = metadata.contentType ?? ""
        cacheControl = metadata.cacheControl ?? ""
        contentDisposition = metadata.contentDisposition ?? ""
        contentEncoding = metadata.contentEncoding ?? ""
        contentLanguage = metadata.contentLanguage ?? ""
        storageClass = metadata.storageClass ?? defaultStorageClass
        self.metadata = metadata.userMetadata.sorted { $0.key < $1.key }.map { Pair(key: $0.key, value: $0.value) }
        self.tags = tags.map { Pair(key: $0.key, value: $0.value) }
    }

    /// Validation problems (empty when the draft can be saved).
    var problems: [String] {
        var result: [String] = []
        for pair in metadata {
            do { try MetadataRules.validate(key: pair.key, value: pair.value) } catch { result.append(describe(error)) }
        }
        if Set(metadata.map { $0.key.lowercased() }).count != metadata.count { result.append("Metadata names must be unique.") }
        do { try MetadataRules.validate(tags: tags.map { ObjectTag(key: $0.key, value: $0.value) }) } catch { result.append(describe(error)) }
        for value in [contentType, cacheControl, contentDisposition, contentEncoding, contentLanguage]
            where value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            result.append("Header values cannot contain control characters.")
            break
        }
        return result
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum PreviewContent {
    case idle
    case loading
    case text(String, truncated: Bool, totalSize: Int64)
    case image(NSImage)
    case pdf(PDFDocument)
    case file(URL)
    case unavailable(String)
}

/// Loads previews according to `PreviewPlan` (ranged GETs, size limits, QuickLook files in a temp folder).
enum PreviewLoader {
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CcinnBucket-Previews", isDirectory: true)

    static func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    static func load(bucket: String, key: String, versionID: String?, contentType: String?, size: Int64,
                     storage: any ObjectStorage) async -> PreviewContent {
        let plan = PreviewPlan.make(key: key, contentType: contentType, size: size)
        do {
            switch plan.kind {
            case .empty:
                return .unavailable(key.hasSuffix("/") ? "Folder marker" : "Empty object")
            case .tooLarge:
                return .unavailable("Too large to preview (\(SizeFormat.bytes(size))). Download it instead.")
            case .text:
                let limit = Int(min(size, PreviewPlan.textLimit))
                let data = try await storage.getObject(bucket: bucket, key: key, versionID: versionID, range: plan.range, maxBytes: max(1, limit) + 1)
                let text = await Task.detached { Self.decodeText(data.data) }.value
                return .text(text, truncated: plan.isTruncated, totalSize: size)
            case .json:
                let data = try await storage.getObject(bucket: bucket, key: key, versionID: versionID, range: nil, maxBytes: Int(PreviewPlan.jsonLimit) + 1)
                let text = await Task.detached { Self.prettyJSON(data.data) ?? Self.decodeText(data.data) }.value
                return .text(text, truncated: false, totalSize: size)
            case .image:
                let data = try await storage.getObject(bucket: bucket, key: key, versionID: versionID, range: nil, maxBytes: Int(PreviewPlan.imageLimit) + 1)
                if let image = NSImage(data: data.data) { return .image(image) }
                return try await quickLookFile(bucket: bucket, key: key, versionID: versionID, storage: storage)
            case .pdf:
                let data = try await storage.getObject(bucket: bucket, key: key, versionID: versionID, range: nil, maxBytes: Int(PreviewPlan.documentLimit) + 1)
                if let document = PDFDocument(data: data.data) { return .pdf(document) }
                return .unavailable("The PDF could not be opened.")
            case .quickLook:
                return try await quickLookFile(bucket: bucket, key: key, versionID: versionID, storage: storage)
            }
        } catch {
            let wrapped = StorageError.wrap(error)
            return wrapped.isCancellation ? .idle : .unavailable(wrapped.description)
        }
    }

    private static func quickLookFile(bucket: String, key: String, versionID: String?, storage: any ObjectStorage) async throws -> PreviewContent {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard let destination = LocalPathMapper.localURL(forKey: ObjectPath.lastComponent(of: key), relativeTo: "", root: folder) else {
            return .unavailable("This object cannot be previewed.")
        }
        try await ObjectDownloader(storage: storage, limiter: AsyncLimiter(limit: 4)).download(bucket: bucket, key: key, versionID: versionID,
                                                                                              to: destination, progress: { _ in })
        return .file(destination)
    }

    nonisolated static func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        // A range may end inside a multi-byte character: drop up to 3 trailing bytes before falling back.
        for trim in 1...3 where data.count > trim {
            if let text = String(data: data.dropLast(trim), encoding: .utf8) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }
}

/// Details, preview and metadata editing for one selected object.
@MainActor
@Observable
final class InspectorModel {
    let row: ListingRow
    let bucket: String
    let storage: any ObjectStorage
    private weak var workspace: WorkspaceModel?

    private(set) var metadata: ObjectMetadata?
    private(set) var tags: [ObjectTag]?
    private(set) var tagsError: String?
    private(set) var isLoading = false
    var error: String?
    private(set) var preview: PreviewContent = .idle
    var draft: MetadataDraft?
    private(set) var isSaving = false

    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    init(row: ListingRow, bucket: String, storage: any ObjectStorage, workspace: WorkspaceModel?) {
        self.row = row
        self.bucket = bucket
        self.storage = storage
        self.workspace = workspace
    }

    var versionID: String? { row.version?.versionID }
    var isReadOnly: Bool { workspace?.isReadOnly ?? true }
    var storageClasses: [String] { storage.capabilities.storageClasses }

    func cancel() {
        loadTask?.cancel()
        previewTask?.cancel()
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        error = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let metadata = try await storage.headObject(bucket: bucket, key: row.key, versionID: versionID)
                guard !Task.isCancelled else { return }
                self.metadata = metadata
                self.loadPreview()
            } catch {
                if !Task.isCancelled { self.error = describe(error) }
            }
            self.isLoading = false
            do {
                let tags = try await storage.getObjectTags(bucket: bucket, key: row.key, versionID: versionID)
                if !Task.isCancelled { self.tags = tags }
            } catch {
                if !Task.isCancelled { self.tagsError = describe(error) }
            }
        }
    }

    func loadPreview() {
        previewTask?.cancel()
        preview = .loading
        let size = metadata?.size ?? row.size
        let contentType = metadata?.contentType
        previewTask = Task { [weak self] in
            guard let self else { return }
            let content = await PreviewLoader.load(bucket: bucket, key: row.key, versionID: versionID, contentType: contentType, size: size,
                                                   storage: storage)
            if !Task.isCancelled { self.preview = content }
        }
    }

    func beginEditing() {
        guard let metadata else { return }
        draft = MetadataDraft(metadata: metadata, tags: tags ?? [], defaultStorageClass: storage.capabilities.defaultStorageClass)
    }

    func cancelEditing() { draft = nil }

    /// Applies header/metadata/storage-class changes with a self-copy (REPLACE) and tag changes with PutObjectTagging.
    func save() {
        guard let draft, let metadata, draft.problems.isEmpty, !isReadOnly else { return }
        let original = MetadataDraft(metadata: metadata, tags: tags ?? [], defaultStorageClass: storage.capabilities.defaultStorageClass)
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let headersChanged = draft.contentType != original.contentType || draft.cacheControl != original.cacheControl
                    || draft.contentDisposition != original.contentDisposition || draft.contentEncoding != original.contentEncoding
                    || draft.contentLanguage != original.contentLanguage || draft.storageClass != original.storageClass
                    || draft.metadata.map { [$0.key, $0.value] } != original.metadata.map { [$0.key, $0.value] }
                if headersChanged {
                    var options = metadata.writeOptions
                    options.contentType = MetadataDraft.nonEmpty(draft.contentType)
                    options.cacheControl = MetadataDraft.nonEmpty(draft.cacheControl)
                    options.contentDisposition = MetadataDraft.nonEmpty(draft.contentDisposition)
                    options.contentEncoding = MetadataDraft.nonEmpty(draft.contentEncoding)
                    options.contentLanguage = MetadataDraft.nonEmpty(draft.contentLanguage)
                    options.storageClass = MetadataDraft.nonEmpty(draft.storageClass)
                    options.userMetadata = Dictionary(draft.metadata.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
                    options.serverSideEncryption = metadata.serverSideEncryption
                    _ = try await ServerSideCopier(storage: storage).copy(
                        CopyObjectRequest(sourceBucket: bucket, sourceKey: row.key, sourceVersionID: versionID, destinationBucket: bucket,
                                          destinationKey: row.key, directive: .replace, options: options), knownSize: metadata.size)
                }
                let newTags = draft.tags.map { ObjectTag(key: $0.key.trimmingCharacters(in: .whitespaces), value: $0.value) }
                if newTags != (tags ?? []) {
                    try await storage.putObjectTags(bucket: bucket, key: row.key, versionID: headersChanged ? nil : versionID, tags: newTags)
                }
                self.draft = nil
                self.workspace?.showToast("Saved changes to “\(row.name)”")
                self.load()
                if headersChanged { self.workspace?.browser?.refreshSoon() }
            } catch {
                self.workspace?.showToast(describe(error), isError: true)
            }
            self.isSaving = false
        }
    }
}
