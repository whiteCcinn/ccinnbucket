import AppKit
import CcinnBucketKit
import StorageKit
import SwiftUI

/// Right-hand inspector: preview, overview, headers, user metadata, tags; editable for writable accounts.
struct InspectorView: View {
    let browser: BrowserModel?

    var body: some View {
        Group {
            if let browser, let inspector = browser.inspector {
                ObjectInspector(model: inspector, browser: browser)
                    .id(inspector.row.id)
            } else if let browser, !browser.selection.isEmpty {
                SelectionSummary(rows: browser.selectedRows, browser: browser)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                       description: Text("Select an object to see its details, preview and metadata."))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 280)
    }
}

private struct SelectionSummary: View {
    let rows: [ListingRow]
    let browser: BrowserModel
    @State private var summary: (count: Int, bytes: Int64)?
    @State private var calculating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: rows.count == 1 && rows[0].isFolder ? "folder.fill" : "square.stack.3d.up.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color(nsColor: .folderTint))
                    VStack(alignment: .leading) {
                        Text(rows.count == 1 ? rows[0].name : "\(rows.count) items selected").font(.headline)
                        if rows.count == 1 { Text(rows[0].key).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                Card(title: "Contents", systemImage: "chart.bar.doc.horizontal") {
                    if let summary {
                        KeyValueList(items: [("Objects", summary.count.formatted()), ("Total size", SizeFormat.bytes(summary.bytes))])
                    } else {
                        Button {
                            calculate()
                        } label: {
                            if calculating { ProgressView().controlSize(.small) } else { Text("Calculate Size") }
                        }
                        .disabled(calculating)
                        Text("Counts every object under the selected folders (one listing request per 1,000 objects).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
    }

    private func calculate() {
        calculating = true
        Task {
            var count = 0
            var bytes: Int64 = 0
            for row in rows {
                if row.isFolder {
                    if let result = try? await ObjectEnumerator(storage: browser.storage).summarize(bucket: browser.bucket, prefix: row.key) {
                        count += result.count
                        bytes &+= result.bytes
                    }
                } else {
                    count += 1
                    bytes &+= row.size
                }
            }
            summary = (count, bytes)
            calculating = false
        }
    }
}

private struct ObjectInspector: View {
    @Bindable var model: InspectorModel
    let browser: BrowserModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                previewCard
                if let error = model.error { ErrorBanner(message: error) }
                if model.draft != nil {
                    MetadataEditor(model: model)
                } else if let metadata = model.metadata {
                    overview(metadata)
                    headers(metadata)
                    userMetadata(metadata)
                    tags
                } else if model.isLoading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Theme.symbol(forKey: model.row.key, isFolder: false))
                .font(.system(size: 24))
                .foregroundStyle(Color(nsColor: Theme.nsColor(forKey: model.row.key, isFolder: false)))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.row.name).font(.headline).lineLimit(3).textSelection(.enabled)
                Text(model.row.key).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if model.draft == nil {
                Button("Edit") { model.beginEditing() }
                    .disabled(model.isReadOnly || model.metadata == nil || model.row.kind == .version && model.row.version?.isLatest != true)
                    .help(model.isReadOnly ? "This account is read-only" : "Edit headers, metadata, storage class and tags")
            }
        }
    }

    private var previewCard: some View {
        VStack(spacing: 0) {
            PreviewContentView(content: model.preview)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipped()
            Divider()
            HStack {
                Button { browser.sheet = .preview(model.row) } label: { Label("Open Preview", systemImage: "eye") }
                    .buttonStyle(.borderless)
                Spacer()
                Button { browser.sheet = .presign(model.row) } label: { Label("Share", systemImage: "link") }
                    .buttonStyle(.borderless)
                Button { browser.chooseDownloadDestination(for: [model.row]) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(8)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    private func overview(_ metadata: ObjectMetadata) -> some View {
        Card(title: "Overview", systemImage: "info.circle") {
            var items: [(String, String)] = [
                ("Size", metadata.size < 1_000 ? "\(metadata.size.formatted()) bytes" : "\(SizeFormat.bytes(metadata.size)) (\(metadata.size.formatted()) bytes)"),
                ("Modified", Format.date(metadata.lastModified)),
                ("Storage class", metadata.storageClass ?? browser.storage.capabilities.defaultStorageClass),
                ("ETag", metadata.eTag ?? "—"),
            ]
            if let version = metadata.versionID { items.append(("Version", version)) }
            if let encryption = metadata.serverSideEncryption {
                items.append(("Encryption", encryption + (metadata.kmsKeyID.map { " · \($0)" } ?? "")))
            } else {
                items.append(("Encryption", "None reported"))
            }
            if let parts = metadata.partsCount { items.append(("Parts", parts.formatted())) }
            if let type = metadata.objectType { items.append(("Object type", type)) }
            if let restore = metadata.restoreStatus { items.append(("Restore", restore)) }
            return KeyValueList(items: items)
        }
    }

    private func headers(_ metadata: ObjectMetadata) -> some View {
        Card(title: "HTTP Headers", systemImage: "list.bullet.rectangle") {
            KeyValueList(items: [
                ("Content-Type", metadata.contentType ?? "—"),
                ("Cache-Control", metadata.cacheControl ?? "—"),
                ("Content-Disposition", metadata.contentDisposition ?? "—"),
                ("Content-Encoding", metadata.contentEncoding ?? "—"),
                ("Content-Language", metadata.contentLanguage ?? "—"),
            ], monospacedValues: true)
        }
    }

    private func userMetadata(_ metadata: ObjectMetadata) -> some View {
        Card(title: "Metadata", systemImage: "tag") {
            if metadata.userMetadata.isEmpty {
                Text("No user metadata").foregroundStyle(.secondary).font(.callout)
            } else {
                KeyValueList(items: metadata.userMetadata.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, monospacedValues: true)
            }
        }
    }

    private var tags: some View {
        Card(title: "Tags", systemImage: "number") {
            if let tags = model.tags {
                if tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary).font(.callout)
                } else {
                    FlowTags(tags: tags)
                }
            } else if let error = model.tagsError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

private struct FlowTags: View {
    let tags: [ObjectTag]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.key) { tag in
                HStack(spacing: 0) {
                    Text(tag.key).padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent.opacity(0.18))
                    Text(tag.value.isEmpty ? "—" : tag.value).padding(.horizontal, 7).padding(.vertical, 3).background(Theme.accent.opacity(0.07))
                }
                .font(.caption.monospaced())
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .textSelection(.enabled)
            }
        }
    }
}

/// Edits headers, storage class, user metadata and tags.
private struct MetadataEditor: View {
    @Bindable var model: InspectorModel

    var body: some View {
        if let binding = Binding($model.draft) {
            VStack(alignment: .leading, spacing: 12) {
                Card(title: "HTTP Headers", systemImage: "list.bullet.rectangle") {
                    field("Content-Type", binding.contentType, prompt: "application/octet-stream")
                    field("Cache-Control", binding.cacheControl, prompt: "max-age=3600")
                    field("Content-Disposition", binding.contentDisposition, prompt: "attachment")
                    field("Content-Encoding", binding.contentEncoding, prompt: "gzip")
                    field("Content-Language", binding.contentLanguage, prompt: "en")
                    Picker("Storage class", selection: binding.storageClass) {
                        ForEach(classes(including: binding.wrappedValue.storageClass), id: \.self) { Text($0).tag($0) }
                    }
                }
                pairs(title: "Metadata", systemImage: "tag", items: binding.metadata, keyPrompt: "name", valuePrompt: "value")
                pairs(title: "Tags", systemImage: "number", items: binding.tags, keyPrompt: "key", valuePrompt: "value")
                ForEach(binding.wrappedValue.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                }
                Text("Header, metadata and storage-class changes rewrite the object with a server-side copy\(model.row.size > model.storage.capabilities.maxSingleCopySize ? " (multipart copy for large objects)" : ""); in versioned buckets this creates a new version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { model.cancelEditing() }
                    Spacer()
                    if model.isSaving { ProgressView().controlSize(.small) }
                    Button("Save") { model.save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!binding.wrappedValue.problems.isEmpty || model.isSaving)
                }
            }
        }
    }

    private func classes(including current: String) -> [String] {
        model.storageClasses.contains(current) || current.isEmpty ? model.storageClasses : [current] + model.storageClasses
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).font(Theme.monospacedSmall)
        }
    }

    private func pairs(title: String, systemImage: String, items: Binding<[MetadataDraft.Pair]>, keyPrompt: String, valuePrompt: String) -> some View {
        Card(title: title, systemImage: systemImage) {
            ForEach(items) { $pair in
                HStack(spacing: 6) {
                    TextField(keyPrompt, text: $pair.key).textFieldStyle(.roundedBorder)
                    TextField(valuePrompt, text: $pair.value).textFieldStyle(.roundedBorder)
                    Button { items.wrappedValue.removeAll { $0.id == pair.id } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .font(Theme.monospacedSmall)
            }
            Button { items.wrappedValue.append(MetadataDraft.Pair(key: "", value: "")) } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(.borderless)
                .font(.caption)
        }
    }
}
