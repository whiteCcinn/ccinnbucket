import AppKit
import CcinnBucketKit
import Decompression
import StorageKit
import SwiftUI

/// The preview window (Space, double-click, Open Preview): streams text with progress, shows more on request,
/// copies, and — on writable accounts — edits text in place. Saving asks twice and only replaces the object if it
/// is still the version that was opened.
struct PreviewSheet: View {
    @State private var session: PreviewSession
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDiscard = false
    @State private var closeAfterDiscard = false

    init(row: ListingRow, model: BrowserModel) {
        _session = State(initialValue: PreviewSession(row: row, browser: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = session.error {
                ErrorBanner(message: error).padding(8)
            }
            if let preview = session.textPreview, preview.linesCut > 0, !session.isEditing {
                NoticeBanner(message: "\(preview.linesCut) very long line\(preview.linesCut == 1 ? " is" : "s are") shortened for display. Copy All copies the full text.",
                             systemImage: "text.alignleft")
                    .padding(8)
            }
            if session.isEditing, session.textPreview?.compactsOnSave == true {
                NoticeBanner(message: "This minified JSON is edited indented and saved minified again: only what you change is changed.",
                             systemImage: "curlybraces")
                    .padding(8)
            }
            PreviewContentView(content: session.content, style: .window, textController: session.textController,
                               showsRaw: session.showsRaw, isEditing: session.isEditing, acceptsTyping: session.acceptsTyping)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.textPreview != nil || session.isLoadingMore {
                Divider()
                footer
            }
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 520, idealHeight: 680)
        .interactiveDismissDisabled(session.textController.hasChanges || session.isSaveInProgress)
        .onAppear { session.start() }
        .onDisappear { session.cancel() }
        .confirmationDialog("Save changes to “\(session.row.name)”?", isPresented: $session.showsFirstConfirmation, titleVisibility: .visible) {
            Button("Continue…") { session.confirmFirstStep() }
            Button("Cancel", role: .cancel) { session.cancelSave() }
        } message: {
            if let review = session.review { Text(firstConfirmationMessage(review)) }
        }
        .alert("Replace “\(session.row.name)” on the server?", isPresented: $session.showsSecondConfirmation) {
            Button("Replace Object", role: .destructive) { session.save() }
            Button("Cancel", role: .cancel) { session.cancelSave() }
        } message: {
            if let review = session.review {
                Text(review.keepsPreviousVersion
                     ? "Versioning is on: the current content stays available as a previous version."
                     : "Versioning is off: the current content is overwritten and cannot be recovered.")
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) {
                session.discardEdits()
                if closeAfterDiscard { dismiss() }
            }
            Button("Keep Editing", role: .cancel) { closeAfterDiscard = false }
        } message: {
            Text("Nothing has been saved to the server.")
        }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: Theme.symbol(forKey: session.row.key, isFolder: false))
                .foregroundStyle(Color(nsColor: Theme.nsColor(forKey: session.row.key, isFolder: false)))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.row.name).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let preview = session.textPreview {
                if preview.isJSON {
                    Picker("", selection: $session.showsRaw) {
                        Text("Formatted").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(session.isEditing || !preview.rawIsViewable)
                    .help(!preview.rawIsViewable ? "The stored text is one very long line; Copy All copies it exactly."
                          : session.isEditing ? "Editing uses the stored text" : "Indented JSON, or the text as stored")
                }
                Button { session.copyAll() } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    .help("Copy all the text shown (or select part of it and press ⌘C)")
                editButtons(preview)
            }
            Button("Done", action: close).keyboardShortcut(.cancelAction).disabled(session.isSaveInProgress)
        }
        .padding(14)
    }

    @ViewBuilder
    private func editButtons(_ preview: TextPreview) -> some View {
        if session.isEditing {
            Button("Cancel Editing") {
                if session.textController.hasChanges {
                    closeAfterDiscard = false
                    confirmsDiscard = true
                } else {
                    session.discardEdits()
                }
            }
            .disabled(session.isSaveInProgress)
            Button {
                session.prepareSave()
            } label: {
                if session.isSaving || session.isPreparingSave { ProgressView().controlSize(.small) } else { Text("Save…") }
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!session.textController.hasChanges || session.isSaving || session.isPreparingSave)
            .help("Review and confirm twice before anything is uploaded")
        } else {
            let blocker = session.editBlocker(preview)
            Button { session.beginEditing() } label: { Label("Edit", systemImage: "pencil") }
                .disabled(blocker != nil)
                .help(blocker ?? "Edit the text; saving asks for confirmation twice")
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.isLoadingMore {
                ProgressView(value: session.moreProgress?.fraction ?? 0).frame(width: 160)
                Text(session.moreProgress.map(PreviewProgressView.describe) ?? "Connecting…")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
                Button("Stop") { session.stopLoading() }.controlSize(.small)
            } else if let preview = session.textPreview {
                Text(status(preview)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
                if !preview.isComplete {
                    Button("Show More") { session.showMore() }
                        .controlSize(.small)
                        .disabled(!session.canShowMore || session.isEditing)
                        .help(session.canShowMore ? "Load the next \(SizeFormat.bytes(Int64(PreviewBudget.stepBytes)))"
                              : "The preview shows at most \(SizeFormat.bytes(Int64(PreviewBudget.maximumBytes))); download the object to see all of it.")
                }
            }
            Spacer()
            if session.isEditing {
                Label("Editing — nothing is uploaded until you confirm twice", systemImage: "pencil.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        var parts = [SizeFormat.bytes(session.row.size)]
        if let compression = session.textPreview?.compression { parts.append(compression.displayName) }
        parts.append(session.row.key)
        return parts.joined(separator: " · ")
    }

    private func status(_ preview: TextPreview) -> String {
        let shown = SizeFormat.bytes(preview.shownBytes)
        if preview.isComplete {
            return preview.compression == nil ? "Whole object · \(shown)" : "Whole object · \(shown) decompressed"
        }
        let what = preview.compression == nil ? "Showing the first \(shown)" : "Showing the first \(shown) decompressed"
        return "\(what) · downloaded \(SizeFormat.bytes(preview.progress.receivedBytes)) of \(SizeFormat.bytes(preview.progress.totalBytes))"
    }

    private func firstConfirmationMessage(_ review: PreviewSession.SaveReview) -> String {
        var text = review.jsonProblem.map { "⚠︎ This is not valid JSON (\($0)). It will be saved as it is.\n\n" } ?? ""
        text += "\(session.row.key) in \(session.bucket)\n\(SizeFormat.bytes(review.oldSize)) → \(SizeFormat.bytes(Int64(review.body.count)))"
        if let compression = review.compression { text += " (\(compression.displayName), compressed again)" }
        text += "\n\nKept: headers, user metadata, storage class, encryption and tags. Not copied: the object's ACL (the bucket default applies), Object Lock retention and legal hold, and website redirects."
        text += "\nThe object's ETag is checked right before uploading; if it changed since you opened it, nothing is saved."
        return text
    }

    private func close() {
        if session.textController.hasChanges {
            closeAfterDiscard = true
            confirmsDiscard = true
        } else {
            dismiss()
        }
    }
}
