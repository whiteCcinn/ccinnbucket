import AppKit
import CcinnBucketKit
import StorageKit
import SwiftUI

/// Path bar, object table, status bar and every confirmation of the object browser.
struct BrowserView: View {
    @Bindable var model: BrowserModel
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            PathBar(model: model, workspace: workspace)
            Divider()
            ZStack {
                if model.isColumnView {
                    ColumnBrowserView(model: model, workspace: workspace)
                } else {
                    ObjectTable(rows: model.rows, revision: model.rowsRevision, selection: model.selection,
                                showsVersions: model.mode == .versions, sortColumn: model.sortColumn, sortAscending: model.sortAscending,
                                acceptsDrops: !model.isReadOnly, actions: tableActions)
                    listingOverlay
                }
                busyOverlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(model: model)
        }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case let .newFolder(parent): NewFolderSheet(model: model, parent: parent)
            case let .rename(row): RenameSheet(model: model, row: row)
            case let .transfer(rows, move): TransferDestinationSheet(model: model, workspace: workspace, rows: rows, move: move)
            case let .presign(row): PresignSheet(model: model, row: row, maximum: workspace.capabilities.maxPresignExpiry)
            case let .preview(row): PreviewSheet(row: row, model: model)
            }
        }
        .confirmationDialog(model.pendingDelete?.title ?? "", isPresented: Binding(get: { model.pendingDelete != nil },
                                                                                    set: { if !$0 { model.pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(model.pendingDelete?.permanent == true ? "Delete Permanently" : "Delete", role: .destructive) { model.confirmDelete() }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text(model.pendingDelete?.message ?? "")
        }
        .confirmationDialog(uploadConflictTitle, isPresented: Binding(get: { model.pendingUploadConflict != nil },
                                                                       set: { if !$0 { model.pendingUploadConflict = nil } }),
                            titleVisibility: .visible) {
            Button("Replace") { model.resolveUploadConflict(replace: true) }
            Button("Skip Existing") { model.resolveUploadConflict(replace: false) }
            Button("Cancel", role: .cancel) { model.pendingUploadConflict = nil }
        } message: {
            Text("Objects with the same keys already exist in \(model.bucket)/\(model.prefix).")
        }
    }

    private var uploadConflictTitle: String {
        guard let conflict = model.pendingUploadConflict else { return "" }
        return conflict.existing.count == 1 ? "Replace “\(ObjectPath.lastComponent(of: conflict.existing.first ?? ""))”?"
            : "Replace \(conflict.existing.count.formatted()) existing objects?"
    }

    /// Loading, error and empty states of the list.
    @ViewBuilder
    private var listingOverlay: some View {
        if let error = model.error, model.rows.isEmpty {
            VStack(spacing: 12) {
                ErrorBanner(message: error)
                Button("Try Again") { model.reload() }
            }
            .padding(30)
            .frame(maxWidth: 560)
        } else if model.isLoading, model.rows.isEmpty {
            ProgressView("Listing \(model.prefix.isEmpty ? model.bucket : model.prefix)…")
                .controlSize(.small)
        } else if model.rows.isEmpty {
            ContentUnavailableView {
                Label(model.filterText.isEmpty ? "Empty Folder" : "No Matches", systemImage: model.filterText.isEmpty ? "tray" : "magnifyingglass")
            } description: {
                if model.filterText.isEmpty {
                    Text(model.isReadOnly ? "This folder has no objects." : "Drop files or folders here to upload them.")
                } else {
                    Text("No keys start with “\(model.prefix)\(model.filterText)”.")
                }
            }
        }
    }

    /// Progress of counting objects for an operation (both views).
    @ViewBuilder
    private var busyOverlay: some View {
        if let message = model.busyMessage {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.callout)
                    Button("Cancel") { model.cancelBusy() }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(.bottom, 16)
            }
        }
    }

    private var tableActions: ObjectTableActions {
        var actions = ObjectTableActions()
        actions.open = { model.open($0) }
        actions.selectionChanged = { model.selection = $0 }
        actions.nearEnd = { model.loadMoreIfNeeded() }
        actions.sort = { model.setSort($0, ascending: $1) }
        actions.dropFiles = { urls, folder in model.upload(urls, into: folder) }
        actions.delete = { model.requestDelete($0) }
        actions.quickLook = { model.sheet = .preview($0) }
        actions.menu = { rows in ObjectMenuBuilder(model: model, workspace: workspace).menu(for: rows, folder: model.prefix) }
        return actions
    }
}

/// Breadcrumbs, filter field and the objects/versions switch.
private struct PathBar: View {
    @Bindable var model: BrowserModel
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb(title: model.bucket, prefix: "", systemImage: "shippingbox.fill", isLast: model.breadcrumbs.isEmpty)
                    ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary).font(.system(size: 13))
                        self.crumb(title: crumb.title.isEmpty ? "(empty)" : crumb.title, prefix: crumb.prefix, systemImage: nil,
                                   isLast: index == model.breadcrumbs.count - 1)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter by prefix", text: $model.filterText)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
                if !model.filterText.isEmpty {
                    Button { model.filterText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .help("Shows keys starting with this text in the current folder (server-side)")
            if model.isColumnView {
                SortMenu(model: model)
            }
            Picker("", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("Objects").tag(BrowserModel.Mode.objects)
                Text("Versions").tag(BrowserModel.Mode.versions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            .help("Show every version and delete marker")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func crumb(title: String, prefix: String, systemImage: String?, isLast: Bool) -> some View {
        Button {
            model.navigate(to: prefix)
        } label: {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(isLast ? .semibold : .regular))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isLast ? AnyShapeStyle(Theme.accent.opacity(0.12)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isReadOnly else { return false }
            model.upload(urls, into: prefix)
            return true
        }
        .help(prefix.isEmpty ? "\(model.bucket) (bucket root)" : prefix)
    }
}

/// Sort order for the column view, which has no column headers.
private struct SortMenu: View {
    let model: BrowserModel

    var body: some View {
        Menu {
            Picker("Sort By", selection: Binding(get: { model.sortColumn }, set: { model.setSort($0, ascending: model.sortAscending) })) {
                Text("Name").tag(ListingSortColumn.name)
                Text("Size").tag(ListingSortColumn.size)
                Text("Last Modified").tag(ListingSortColumn.modified)
                Text("Storage Class").tag(ListingSortColumn.storageClass)
                Text("Kind").tag(ListingSortColumn.kind)
            }
            .pickerStyle(.inline)
            Picker("Order", selection: Binding(get: { model.sortAscending }, set: { model.setSort(model.sortColumn, ascending: $0) })) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort the columns (folders stay first)")
    }
}

/// Counts, paging state and selection summary.
private struct StatusBar: View {
    let model: BrowserModel

    var body: some View {
        HStack(spacing: 10) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if model.isLoadingAll {
                ProgressView().controlSize(.mini)
                Button("Stop") { model.stopLoadingAll() }.buttonStyle(.link).font(.caption)
            } else if model.hasMore {
                if model.isLoadingMore { ProgressView().controlSize(.mini) }
                Button("Load More") { model.loadMoreIfNeeded() }.buttonStyle(.link).font(.caption)
                Button("Load All") { model.loadAll() }.buttonStyle(.link).font(.caption)
            }
            Spacer()
            if !model.selection.isEmpty {
                Text(selectionSummary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if model.isReadOnly {
                Badge(text: "Read-only", color: .orange, systemImage: "lock.fill")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var summary: String {
        var parts: [String] = []
        if model.folderCount > 0 { parts.append("\(model.folderCount.formatted()) folder\(model.folderCount == 1 ? "" : "s")") }
        let noun = model.mode == .versions ? "version" : "object"
        parts.append("\(model.objectCount.formatted()) \(noun)\(model.objectCount == 1 ? "" : "s")")
        parts.append(SizeFormat.bytes(model.loadedBytes))
        var text = parts.joined(separator: " · ")
        if model.hasMore { text += " loaded · more available" }
        return text
    }

    private var selectionSummary: String {
        let rows = model.selectedRows
        let bytes = rows.reduce(Int64(0)) { $0 &+ ($1.isFolder ? 0 : $1.size) }
        return "\(rows.count.formatted()) selected" + (bytes > 0 ? " · \(SizeFormat.bytes(bytes))" : "")
    }
}

/// Context menu for table rows.
@MainActor
struct ObjectMenuBuilder {
    let model: BrowserModel
    let workspace: WorkspaceModel

    final class Handler: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }

    private func item(_ title: String, _ symbol: String, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
        let handler = Handler(action)
        let item = NSMenuItem(title: title, action: #selector(Handler.run), keyEquivalent: "")
        item.target = handler
        item.representedObject = handler
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = enabled
        return item
    }

    /// - Parameter folder: the folder of the list or column, for New Folder and Upload on its blank area.
    func menu(for rows: [ListingRow], folder: String) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let writable = !model.isReadOnly
        guard !rows.isEmpty else {
            menu.addItem(item("New Folder…", "folder.badge.plus", enabled: writable) { model.sheet = .newFolder(parent: folder) })
            menu.addItem(item("Upload Files…", "arrow.up.doc", enabled: writable) { UploadPanel.run(model: model, into: folder) })
            menu.addItem(.separator())
            menu.addItem(item("Refresh", "arrow.clockwise") { model.reload() })
            return menu
        }
        let single = rows.count == 1 ? rows[0] : nil
        let isVersion = rows.allSatisfy { $0.kind == .version }
        let anyVersion = rows.contains { $0.kind == .version }
        if let single, single.isFolder {
            menu.addItem(item("Open", "folder") { model.open(single) })
        } else if let single, !(single.version?.isDeleteMarker ?? false) {
            menu.addItem(item("Quick Look", "eye") { model.sheet = .preview(single) })
        }
        menu.addItem(item(rows.count == 1 ? "Download…" : "Download \(rows.count) Items…", "arrow.down.circle") {
            model.chooseDownloadDestination(for: rows)
        })
        if let single, !single.isFolder, !(single.version?.isDeleteMarker ?? false) {
            menu.addItem(item("Share Link…", "link") { model.sheet = .presign(single) })
        }
        menu.addItem(.separator())
        if isVersion, let single, let version = single.version {
            menu.addItem(item("Restore This Version", "clock.arrow.circlepath", enabled: writable && !version.isDeleteMarker) { model.restore(single) })
        } else if !anyVersion {
            if let single {
                menu.addItem(item("Rename…", "pencil", enabled: writable) { model.sheet = .rename(single) })
            }
            menu.addItem(item("Copy To…", "doc.on.doc", enabled: writable) { model.sheet = .transfer(rows: rows, move: false) })
            menu.addItem(item("Move To…", "arrow.right.doc.on.clipboard", enabled: writable) { model.sheet = .transfer(rows: rows, move: true) })
        }
        menu.addItem(.separator())
        menu.addItem(item(rows.count == 1 ? "Copy Key" : "Copy Keys", "key") { model.copyKey(rows) })
        menu.addItem(item(workspace.capabilities.provider == .oss ? "Copy oss:// URI" : "Copy s3:// URI", "link.badge.plus") { model.copyURI(rows) })
        menu.addItem(.separator())
        menu.addItem(item(isVersion ? "Delete Permanently…" : "Delete…", "trash", enabled: writable && (isVersion || !anyVersion)) { model.requestDelete(rows) })
        return menu
    }
}

enum UploadPanel {
    /// - Parameter folder: where to upload; the current folder when `nil`.
    @MainActor
    static func run(model: BrowserModel, into folder: String? = nil) {
        let destination = folder ?? model.prefix
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to upload to \(model.bucket)/\(destination)"
        guard panel.runModal() == .OK else { return }
        model.upload(panel.urls, into: destination)
    }
}
