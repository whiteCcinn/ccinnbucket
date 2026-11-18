import AppKit
import CcinnBucketKit
import PDFKit
import Quartz
import StorageKit
import SwiftUI

/// Common sheet chrome: title, content, and a button row.
private struct SheetScaffold<Content: View, Buttons: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }
                }
            }
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
    }
}

struct NewFolderSheet: View {
    let model: BrowserModel
    /// The folder the new folder goes into.
    let parent: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        SheetScaffold(title: "New Folder", subtitle: "in \(model.bucket)/\(parent)", systemImage: "folder.badge.plus") {
            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            Text("Creates a zero-byte “\(name.isEmpty ? "name" : name)/” marker so the folder shows up while it is empty.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(name.isEmpty || working)
        }
        .frame(width: 420)
    }

    private func create() {
        working = true
        Task {
            problem = await model.createFolder(named: name, in: parent)
            working = false
            if problem == nil { dismiss() }
        }
    }
}

struct RenameSheet: View {
    let model: BrowserModel
    let row: ListingRow
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        SheetScaffold(title: "Rename \(row.isFolder ? "Folder" : "Object")", subtitle: row.key, systemImage: "pencil") {
            TextField("New name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            Text(row.isFolder ? "Object storage has no real folders: every object under the folder is copied to the new name and then deleted."
                : "The object is copied server-side to the new key, then the original is deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Rename", action: rename).keyboardShortcut(.defaultAction).disabled(name.isEmpty || name == row.name || working)
        }
        .frame(width: 440)
        .onAppear { name = row.name }
    }

    private func rename() {
        working = true
        Task {
            problem = await model.rename(row, to: name)
            working = false
            if problem == nil { dismiss() }
        }
    }
}

struct TransferDestinationSheet: View {
    let model: BrowserModel
    let workspace: WorkspaceModel
    let rows: [ListingRow]
    let move: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var bucket = ""
    @State private var prefix = ""

    var body: some View {
        SheetScaffold(title: move ? "Move \(itemsDescription)" : "Copy \(itemsDescription)", subtitle: "from \(model.bucket)/\(model.prefix)",
                      systemImage: move ? "arrow.right.doc.on.clipboard" : "doc.on.doc") {
            Form {
                Picker("Bucket", selection: $bucket) {
                    ForEach(workspace.buckets) { Text($0.name).tag($0.name) }
                }
                TextField("Folder", text: $prefix, prompt: Text("photos/2024/ (empty = bucket root)"))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("Copies happen inside the service (no data passes through this Mac). Objects with the same keys at the destination are replaced.\(move ? " Originals are deleted after each copy succeeds." : "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(move ? "Move" : "Copy") {
                var destination = prefix.trimmingCharacters(in: .whitespaces)
                if !destination.isEmpty, !destination.hasSuffix("/") { destination += "/" }
                model.transfer(rows, toBucket: bucket, prefix: destination, move: move)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(bucket.isEmpty)
        }
        .frame(width: 480)
        .onAppear {
            bucket = model.bucket
            prefix = model.prefix
        }
    }

    private var itemsDescription: String { rows.count == 1 ? "“\(rows[0].name)”" : "\(rows.count) Items" }
}

struct PresignSheet: View {
    let model: BrowserModel
    let row: ListingRow
    let maximum: Int
    @Environment(\.dismiss) private var dismiss
    @State private var expiry = 3_600
    @State private var customHours = 2.0
    @State private var useCustom = false
    @State private var forceDownload = false
    @State private var url: URL?
    @State private var problem: String?
    @State private var copied = false

    var body: some View {
        SheetScaffold(title: "Share Link", subtitle: row.key, systemImage: "link") {
            Form {
                Picker("Expires after", selection: $expiry) {
                    ForEach(PresignExpiry.presets) { Text($0.title).tag($0.seconds) }
                    Text("Custom…").tag(-1)
                }
                if expiry == -1 {
                    Stepper(value: $customHours, in: 0.25...Double(maximum) / 3_600, step: 0.25) {
                        Text("\(customHours, specifier: "%.2f") hours")
                    }
                }
                Toggle("Download as attachment", isOn: $forceDownload)
                if let version = row.version {
                    LabeledContent("Version", value: version.versionID)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if let url {
                HStack(alignment: .top) {
                    Text(url.absoluteString)
                        .font(Theme.monospacedSmall)
                        .textSelection(.enabled)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Copied" : "Copy") {
                        Pasteboard.copy(url.absoluteString)
                        copied = true
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
                Text("Anyone with this link can download the object until it expires. Links signed with temporary (STS) credentials stop working when those expire.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem { ErrorBanner(message: problem) }
        } buttons: {
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create Link") { generate() }.keyboardShortcut(.defaultAction)
        }
        .frame(width: 520)
    }

    private var seconds: Int { expiry == -1 ? Int((customHours * 3_600).rounded()) : expiry }

    private func generate() {
        problem = PresignExpiry.validate(seconds: seconds, maximum: maximum)
        guard problem == nil else { return }
        Task {
            do {
                let link = try await model.presignedURL(for: row, expires: seconds, downloadName: forceDownload ? row.name : nil)
                url = link
                Pasteboard.copy(link.absoluteString)
                copied = true
            } catch {
                problem = describe(error)
            }
        }
    }
}
