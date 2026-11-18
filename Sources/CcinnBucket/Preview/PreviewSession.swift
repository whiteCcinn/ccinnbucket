import CcinnBucketKit
import Decompression
import Foundation
import Observation
import StorageKit

/// State and work of one preview window: loading with progress, Show More, and editing with a two-step save.
@MainActor
@Observable
final class PreviewSession {
    /// Text objects up to this size (decoded) can be edited.
    static let editLimit: Int64 = 16 << 20

    struct SaveReview {
        var body: Data
        var oldSize: Int64
        var compression: CompressionFormat?
        var eTag: String?
        var keepsPreviousVersion: Bool
        /// Set when JSON is saved that does not parse (shown in the first confirmation).
        var jsonProblem: String?
    }

    let row: ListingRow
    @ObservationIgnored private weak var browser: BrowserModel?
    @ObservationIgnored private let storage: any ObjectStorage
    let bucket: String

    private(set) var content: PreviewContent = .loading(nil)
    private(set) var isLoadingMore = false
    private(set) var moreProgress: PreviewProgress?
    private(set) var limit = PreviewBudget.window.initialBytes
    var showsRaw = false
    private(set) var isEditing = false
    let textController = TextViewController()
    /// The prepared save, between "Save…" and the second confirmation.
    private(set) var review: SaveReview?
    var showsFirstConfirmation = false
    var showsSecondConfirmation = false
    private(set) var isPreparingSave = false
    private(set) var isSaving = false
    var error: String?

    @ObservationIgnored private var stream: PreviewStream?
    @ObservationIgnored private var isJSON = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(row: ListingRow, browser: BrowserModel) {
        self.row = row
        self.browser = browser
        storage = browser.storage
        bucket = browser.bucket
    }

    var textPreview: TextPreview? {
        if case let .text(preview) = content { return preview }
        return nil
    }

    var isReadOnly: Bool { browser?.isReadOnly ?? true }

    /// A save is being prepared, confirmed or uploaded: the text is frozen so nothing typed now is silently lost.
    var isSaveInProgress: Bool { isPreparingSave || isSaving || review != nil }

    /// The text can be typed in.
    var acceptsTyping: Bool { isEditing && !isSaveInProgress }

    func cancel() { task?.cancel() }

    // MARK: Loading

    func start() {
        task?.cancel()
        content = .loading(nil)
        limit = PreviewBudget.window.initialBytes
        let row = row
        let storage = storage
        let bucket = bucket
        task = Task { [weak self] in
            let loaded = await PreviewLoader.load(bucket: bucket, key: row.key, versionID: row.version?.versionID, contentType: nil,
                                                  size: row.size, storage: storage, budget: .window) { [weak self] progress in
                guard let self, case .loading = self.content else { return }
                self.content = .loading(progress)
            }
            guard let self, !Task.isCancelled else { return }
            self.stream = loaded.stream
            self.isJSON = loaded.plan.isJSON
            self.content = loaded.content
        }
    }

    var canShowMore: Bool { limit < PreviewBudget.maximumBytes }

    func showMore() {
        guard let stream, !isLoadingMore, canShowMore, !isEditing else { return }
        let target = min(limit + PreviewBudget.stepBytes, PreviewBudget.maximumBytes)
        isLoadingMore = true
        moreProgress = textPreview?.progress
        error = nil
        let isJSON = isJSON
        task = Task { [weak self] in
            do {
                let next = try await PreviewLoader.loadText(stream, upTo: target, isJSON: isJSON) { [weak self] progress in
                    guard let self, self.isLoadingMore else { return }
                    self.moreProgress = progress
                }
                self?.limit = target
                self?.content = next
            } catch {
                // Stopped: keep what is shown. Failed: say so above the text.
                if !(error is CancellationError) { self?.error = "Could not load more: \(describe(error))" }
            }
            self?.isLoadingMore = false
            self?.moreProgress = nil
        }
    }

    func stopLoading() { task?.cancel() }

    // MARK: Editing

    /// Why editing is not offered for the text shown, or `nil` when it is.
    func editBlocker(_ preview: TextPreview) -> String? {
        if isReadOnly { return "This account is read-only." }
        if row.kind != .object { return "Versions can't be edited. Restore the version first." }
        if !preview.isComplete { return "Only the beginning is loaded. Show More until the whole object is loaded to edit it." }
        if !preview.isExact { return "The content is not valid UTF-8 text, so it can't be edited without changing other bytes." }
        if preview.shownBytes > Self.editLimit { return "Objects larger than \(SizeFormat.bytes(Self.editLimit)) can't be edited here." }
        if preview.eTag == nil { return "The server did not report an ETag, so changes made meanwhile could not be detected." }
        if let warning = preview.structureWarning { return warning + " Editing is not offered." }
        if preview.editableText == nil {
            return "A line is too long to edit here (\(preview.longestLine.formatted()) characters; the limit is \(TextLines.displayLimit.formatted()))."
        }
        return nil
    }

    /// Copies the whole text: the exact stored text, or the edited text while editing.
    func copyAll() {
        guard let preview = textPreview else { return }
        TextViewController.copy(isEditing ? textController.text : preview.rawText)
    }

    func beginEditing() {
        guard let preview = textPreview, editBlocker(preview) == nil else { return }
        error = nil
        textController.markClean()
        isEditing = true
    }

    /// Leaves editing and puts the loaded text back.
    func discardEdits() {
        isEditing = false
        review = nil
        textController.markClean()
    }

    /// Encodes the edit (compressing as the original) and shows the first confirmation.
    func prepareSave() {
        guard isEditing, let preview = textPreview, !isPreparingSave, !isSaving else { return }
        let edited = textController.text
        let compacts = preview.compactsOnSave
        let compression = preview.compression
        let storage = storage
        let bucket = bucket
        isPreparingSave = true
        error = nil
        Task { [weak self] in
            do {
                let isJSON = preview.isJSON
                let (body, jsonProblem) = try await Task.detached(priority: .userInitiated) {
                    // Minified JSON was edited indented: compact it again so only the edited tokens change.
                    let text = compacts ? JSONIndenter.compact(edited) : edited
                    return (try ObjectTextSaver.encode(text, compression: compression), isJSON ? Self.jsonProblem(in: text) : nil)
                }.value
                let versioning = try? await storage.versioningStatus(bucket: bucket)
                guard let self else { return }
                self.review = SaveReview(body: body, oldSize: self.row.size, compression: compression, eTag: preview.eTag,
                                         keepsPreviousVersion: versioning == .enabled, jsonProblem: jsonProblem)
                self.showsFirstConfirmation = true
            } catch {
                self?.error = "The text could not be prepared for saving: \(describe(error))"
            }
            self?.isPreparingSave = false
        }
    }

    /// Why `text` is not valid JSON, or `nil` when it parses.
    nonisolated static func jsonProblem(in text: String) -> String? {
        do {
            _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            return nil
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            return detail
        }
    }

    /// First confirmation accepted: ask the second one once the first dialog has gone.
    func confirmFirstStep() {
        guard review != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.review != nil else { return }
            self.showsSecondConfirmation = true
        }
    }

    func cancelSave() { review = nil }

    /// Second confirmation accepted: upload, only if the object is still the version that was opened.
    func save() {
        guard let review, isEditing, !isSaving else { return }
        guard !isReadOnly else {
            error = StorageError.readOnly.message
            return
        }
        isSaving = true
        let storage = storage
        let bucket = bucket
        let key = row.key
        let name = row.name
        Task { [weak self] in
            do {
                try await ObjectTextSaver.save(body: review.body, bucket: bucket, key: key, expectedETag: review.eTag, storage: storage)
                guard let self else { return }
                self.review = nil
                self.isEditing = false
                self.textController.markClean()
                self.browser?.showToast("Saved “\(name)”")
                self.browser?.refreshSoon()
                self.isSaving = false
                self.start()
            } catch {
                self?.review = nil
                self?.error = (error as? LocalizedError)?.errorDescription ?? describe(error)
                self?.isSaving = false
            }
        }
    }
}
