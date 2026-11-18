import CcinnBucketKit
import StorageKit
import SwiftUI

/// Finder-style column view: the bucket root and every folder on the path, each in its own virtualised column,
/// scrolled so the current folder (the last column) is visible.
struct ColumnBrowserView: View {
    @Bindable var model: BrowserModel
    let workspace: WorkspaceModel

    static let columnWidth: CGFloat = 260

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(model.columnPrefixes, id: \.self) { prefix in
                        HStack(spacing: 0) {
                            column(for: prefix)
                                .frame(width: Self.columnWidth)
                            Divider()
                        }
                        .id(prefix)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .onAppear { proxy.scrollTo(model.prefix, anchor: .trailing) }
            .onChange(of: model.prefix) { _, newPrefix in
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(newPrefix, anchor: .trailing) }
            }
        }
    }

    /// One column. The table stays the same view whether the column is the current folder or an ancestor, so it keeps
    /// keyboard focus and its scroll position when the user opens a folder from it.
    private func column(for prefix: String) -> some View {
        let isCurrent = prefix == model.prefix
        let listing = isCurrent ? nil : model.columns.listing(for: prefix)
        let rows = isCurrent ? model.rows : (listing?.rows ?? [])
        let highlight = listing?.highlight.map { Set([$0]) } ?? []
        return ZStack {
            ObjectTable(rows: rows, revision: isCurrent ? model.rowsRevision : (listing?.revision ?? 0),
                        selection: isCurrent ? model.selection : highlight, showsVersions: false,
                        sortColumn: model.sortColumn, sortAscending: model.sortAscending, acceptsDrops: !model.isReadOnly,
                        actions: actions(for: prefix), style: .column, focusRequest: model.focusRequest(for: prefix))
            if isCurrent {
                ColumnStatus(isLoading: model.isLoading, error: model.error, isEmpty: rows.isEmpty,
                             emptyText: model.filterText.isEmpty ? "Empty folder" : "No matches") { model.reload() }
            } else if let listing {
                ColumnStatus(isLoading: listing.isLoading, error: listing.error, isEmpty: rows.isEmpty, emptyText: "Empty folder") {
                    listing.refresh()
                }
            }
        }
    }

    private func actions(for column: String) -> ObjectTableActions {
        var actions = ObjectTableActions()
        actions.open = { model.open($0) }
        actions.selectionChanged = { model.selectInColumn(column, ids: $0) }
        actions.nearEnd = {
            if column == model.prefix {
                model.loadMoreIfNeeded()
            } else {
                model.columns.listing(for: column)?.loadMore()
            }
        }
        actions.dropFiles = { urls, folder in model.upload(urls, into: folder ?? column) }
        actions.delete = { model.requestDelete($0) }
        actions.quickLook = { model.sheet = .preview($0) }
        actions.menu = { rows in ObjectMenuBuilder(model: model, workspace: workspace).menu(for: rows, folder: column) }
        actions.moveLeft = { model.moveColumnFocus(.left, from: column) }
        actions.moveRight = { model.moveColumnFocus(.right, from: column) }
        return actions
    }
}

/// Loading, error and empty states inside one column.
private struct ColumnStatus: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    let emptyText: String
    let retry: () -> Void

    var body: some View {
        if isEmpty {
            Group {
                if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(6)
                        Button("Try Again", action: retry).controlSize(.small)
                    }
                } else if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Text(emptyText).font(.callout).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .allowsHitTesting(error != nil)
        }
    }
}
