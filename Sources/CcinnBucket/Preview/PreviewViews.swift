import AppKit
import CcinnBucketKit
import Decompression
import Observation
import PDFKit
import Quartz
import QuickLookThumbnailing
import SwiftUI

/// Renders `PreviewContent`.
/// - The inspector style uses no AppKit-backed views at all (no PDF or QuickLook view, no scroll view, no selectable
///   text, no `ProgressView`): inside the inspector's scroll view macOS places such views below where SwiftUI draws
///   them, where they cover the Open Preview / Share / Download buttons and swallow their clicks. It shows static
///   text, thumbnails and a drawn progress bar; selecting and copying happen in the preview window.
/// - The window style shows live PDF and QuickLook views and a full text view (selectable, editable when asked).
struct PreviewContentView: View {
    enum Style {
        case inspector
        case window
    }

    let content: PreviewContent
    var style: Style = .inspector
    /// Window style: the text view's controller (selection, editing, current text).
    var textController: TextViewController?
    /// Window style: show the raw text of JSON instead of the indented form.
    var showsRaw = false
    var isEditing = false
    /// Editing, and not frozen by a save in progress.
    var acceptsTyping = true

    var body: some View {
        switch content {
        case .idle:
            Color.clear
        case let .loading(progress):
            PreviewProgressView(progress: progress, compact: style == .inspector)
        case let .text(preview):
            switch style {
            case .inspector:
                StaticTextPreview(text: preview.displayText)
            case .window:
                TextPreviewView(text: windowText(preview), isEditable: isEditing && acceptsTyping, controller: textController ?? TextViewController())
            }
        case let .binary(dump, note):
            VStack(spacing: 0) {
                NoticeBanner(message: note, systemImage: "number").padding(8)
                if style == .window {
                    TextPreviewView(text: dump, isEditable: false, controller: textController ?? TextViewController())
                } else {
                    StaticTextPreview(text: dump)
                }
            }
        case let .image(image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(style == .window ? 16 : 4)
        case let .pdf(document):
            if style == .window {
                PDFKitView(document: document)
            } else {
                PDFThumbnail(document: document)
            }
        case let .file(url):
            if style == .window {
                QuickLookView(url: url)
            } else {
                QuickLookThumbnail(url: url)
            }
        case let .unavailable(message):
            ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text(message))
        }
    }

    /// Editing shows the editable form; Raw the stored text (only when no line is too long to show); otherwise the
    /// display form.
    private func windowText(_ preview: TextPreview) -> String {
        if isEditing { return preview.editableText ?? preview.displayText }
        if showsRaw, preview.rawIsViewable { return preview.rawText }
        return preview.displayText
    }
}

/// The first lines of a text, drawn (not selectable) and clipped to the inspector card.
private struct StaticTextPreview: View {
    let text: String

    var body: some View {
        // One truncated line per text line: the card never grows wider than the inspector, however long a line is.
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(Self.head(of: text).enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(Theme.monospacedSmall)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview text")
    }

    /// As many lines as fit the 200 pt card (so nothing overflows and gets re-aligned), each cut to 200 characters.
    static func head(of text: String) -> [String] {
        text.split(separator: "\n", maxSplits: 10, omittingEmptySubsequences: false).prefix(10).map { String($0.prefix(200)) }
    }
}

/// Download (and decompression) progress, so a long preview is never a silent spinner.
struct PreviewProgressView: View {
    let progress: PreviewProgress?
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            if let progress, progress.totalBytes > 0 {
                if compact {
                    DrawnProgressBar(fraction: progress.fraction).frame(maxWidth: 200)
                } else {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)
                }
                Text(Self.describe(progress))
                    .font(compact ? .caption2 : .callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
            } else {
                if !compact { ProgressView().controlSize(.small) }
                Text("Connecting…").font(compact ? .caption2 : .callout).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func describe(_ progress: PreviewProgress) -> String {
        let percent = Int((progress.fraction * 100).rounded(.down))
        var text = "Downloading \(SizeFormat.bytes(progress.receivedBytes)) of \(SizeFormat.bytes(progress.totalBytes)) (\(percent)%)"
        if let compression = progress.compression {
            text += "\n\(SizeFormat.bytes(progress.decodedBytes)) decompressed (\(compression.displayName))"
        }
        return text
    }
}

/// A progress bar drawn with shapes (the inspector must not contain AppKit-backed views, see `PreviewContentView`).
private struct DrawnProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor).frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Holds the text view of a preview window: current text, unsaved changes, copy.
@MainActor
@Observable
final class TextViewController {
    @ObservationIgnored weak var textView: NSTextView?
    /// The text changed since it was loaded (or since `markClean`).
    private(set) var hasChanges = false
    /// Bumped to make `TextPreviewView` replace its text (load, cancel editing).
    private(set) var contentRevision = 0

    var text: String { textView?.string ?? "" }

    func textDidChange() { if !hasChanges { hasChanges = true } }

    func markClean() {
        hasChanges = false
        contentRevision &+= 1
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// `NSTextView` for previews: monospaced, selectable and copyable (⌘C, ⌘A, ⌘F find), editable on request with undo,
/// and no automatic quote, dash or spelling substitutions (they would silently change data).
struct TextPreviewView: NSViewRepresentable {
    let text: String
    let isEditable: Bool
    let controller: TextViewController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator
        textView.isSelectable = true
        textView.isEditable = isEditable
        textView.string = text
        controller.textView = textView
        context.coordinator.shownText = text
        context.coordinator.shownRevision = controller.contentRevision
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        controller.textView = textView
        let coordinator = context.coordinator
        // Replace the text only when the content changed (not on every SwiftUI update, which would drop edits).
        if coordinator.shownText != text || coordinator.shownRevision != controller.contentRevision {
            coordinator.shownText = text
            coordinator.shownRevision = controller.contentRevision
            textView.string = text
            textView.undoManager?.removeAllActions()
        }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: TextViewController
        var shownText = ""
        var shownRevision = 0

        init(controller: TextViewController) {
            self.controller = controller
        }

        func textDidChange(_ notification: Notification) { controller.textDidChange() }
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document { nsView.document = document }
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? QLPreviewView, (view.previewItem as? NSURL) as URL? != url else { return }
        view.previewItem = url as NSURL
    }
}

/// First page of a PDF as an image (inspector).
private struct PDFThumbnail: View {
    let document: PDFDocument

    var body: some View {
        if let page = document.page(at: 0) {
            Image(nsImage: page.thumbnail(of: NSSize(width: 400, height: 400), for: .mediaBox))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(6)
        } else {
            ContentUnavailableView("No Preview", systemImage: "doc.richtext", description: Text("The PDF has no pages."))
        }
    }
}

/// QuickLook thumbnail of a downloaded file (inspector), or its icon while it is generated.
private struct QuickLookThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(image == nil ? 40 : 6)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 400, height: 400), scale: 2,
                                                           representationTypes: .thumbnail)
                if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                    image = representation.nsImage
                }
            }
    }
}
