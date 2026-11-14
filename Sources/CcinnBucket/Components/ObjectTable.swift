import AppKit
import CcinnBucketKit
import StorageKit
import SwiftUI

/// Callbacks from the object table to its owner.
struct ObjectTableActions {
    var open: (ListingRow) -> Void = { _ in }
    var selectionChanged: (Set<String>) -> Void = { _ in }
    var nearEnd: () -> Void = {}
    var sort: (ListingSortColumn, Bool) -> Void = { _, _ in }
    var dropFiles: ([URL], String?) -> Void = { _, _ in }
    var delete: ([ListingRow]) -> Void = { _ in }
    var quickLook: (ListingRow) -> Void = { _ in }
    var menu: ([ListingRow]) -> NSMenu? = { _ in nil }
}

/// Virtualised object list on `NSTableView`: reused cells, only visible rows are materialised, so 50,000+
/// rows scroll smoothly. Supports sorting, multi-selection, type-select, Finder drops (upload) and keyboard
/// shortcuts (Return opens, Space previews, ⌫ deletes).
struct ObjectTable: NSViewRepresentable {
    let rows: [ListingRow]
    let revision: Int
    let selection: Set<String>
    let showsVersions: Bool
    let sortColumn: ListingSortColumn
    let sortAscending: Bool
    let acceptsDrops: Bool
    let actions: ObjectTableActions

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = ObjectTableView()
        tableView.coordinator = context.coordinator
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsTypeSelect = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tableView.menu = NSMenu()
        tableView.menu?.delegate = context.coordinator
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        context.coordinator.tableView = tableView
        context.coordinator.configureColumns()
        context.coordinator.observeScrolling(scrollView)
        context.coordinator.reload()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let previous = coordinator.parent
        coordinator.parent = self
        if previous.showsVersions != showsVersions { coordinator.configureColumns() }
        if previous.revision != revision || previous.showsVersions != showsVersions {
            coordinator.reload()
        } else if previous.selection != selection {
            coordinator.applySelection()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ObjectTable
        weak var tableView: ObjectTableView?
        private var applyingSelection = false
        private var lastNearEndRequest = -1

        static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            return formatter
        }()

        init(_ parent: ObjectTable) {
            self.parent = parent
        }

        // MARK: Columns

        private struct ColumnSpec {
            let id: String
            let title: String
            let width: CGFloat
            let minWidth: CGFloat
            let sort: ListingSortColumn?
            let alignment: NSTextAlignment
        }

        private var columnSpecs: [ColumnSpec] {
            var specs = [ColumnSpec(id: "name", title: "Name", width: 300, minWidth: 160, sort: .name, alignment: .left)]
            if parent.showsVersions {
                specs.append(ColumnSpec(id: "version", title: "Version ID", width: 180, minWidth: 80, sort: nil, alignment: .left))
                specs.append(ColumnSpec(id: "latest", title: "Latest", width: 60, minWidth: 50, sort: nil, alignment: .center))
            }
            specs += [
                ColumnSpec(id: "size", title: "Size", width: 90, minWidth: 60, sort: .size, alignment: .right),
                ColumnSpec(id: "modified", title: "Last Modified", width: 150, minWidth: 100, sort: .modified, alignment: .left),
                ColumnSpec(id: "class", title: "Storage Class", width: 110, minWidth: 70, sort: .storageClass, alignment: .left),
                ColumnSpec(id: "kind", title: "Kind", width: 80, minWidth: 50, sort: .kind, alignment: .left),
            ]
            return specs
        }

        func configureColumns() {
            guard let tableView else { return }
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            for spec in columnSpecs {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
                column.title = spec.title
                column.width = spec.width
                column.minWidth = spec.minWidth
                column.headerCell.alignment = spec.alignment
                if let sort = spec.sort { column.sortDescriptorPrototype = NSSortDescriptor(key: sort.rawValue, ascending: true) }
                tableView.addTableColumn(column)
            }
            tableView.sortDescriptors = [NSSortDescriptor(key: parent.sortColumn.rawValue, ascending: parent.sortAscending)]
        }

        // MARK: Data

        func reload() {
            guard let tableView else { return }
            tableView.reloadData()
            lastNearEndRequest = -1
            applySelection()
        }

        func applySelection() {
            guard let tableView else { return }
            var indexes = IndexSet()
            if !parent.selection.isEmpty {
                for (index, row) in parent.rows.enumerated() where parent.selection.contains(row.id) { indexes.insert(index) }
            }
            guard indexes != tableView.selectedRowIndexes else { return }
            applyingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            if let first = indexes.first { tableView.scrollRowToVisible(first) }
            applyingSelection = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, parent.rows.indices.contains(row) else { return nil }
            let item = parent.rows[row]
            let id = tableColumn.identifier.rawValue
            if id == "name" { return nameCell(tableView, item) }
            let cell = textCell(tableView, identifier: "text")
            guard let field = cell.textField else { return cell }
            field.alignment = .left
            field.textColor = .secondaryLabelColor
            field.font = .systemFont(ofSize: 12)
            switch id {
            case "size":
                field.alignment = .right
                field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                field.stringValue = item.isFolder || item.version?.isDeleteMarker == true ? "—" : SizeFormat.bytes(item.size)
            case "modified":
                field.stringValue = item.lastModified.map { Self.dateFormatter.string(from: $0) } ?? "—"
            case "class":
                field.stringValue = item.isFolder ? "" : (item.storageClass ?? "STANDARD")
            case "kind":
                field.stringValue = item.typeLabel
            case "version":
                field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                field.stringValue = item.version?.versionID ?? ""
                field.lineBreakMode = .byTruncatingMiddle
            case "latest":
                field.alignment = .center
                field.stringValue = item.version?.isLatest == true ? "✓" : ""
                field.textColor = .controlAccentColor
            default:
                field.stringValue = ""
            }
            cell.toolTip = nil
            return cell
        }

        private func textCell(_ tableView: NSTableView, identifier: String) -> NSTableCellView {
            let id = NSUserInterfaceItemIdentifier(identifier)
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return reused }
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func nameCell(_ tableView: NSTableView, _ item: ListingRow) -> NSView {
            let id = NSUserInterfaceItemIdentifier("name")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyDown
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingMiddle
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.addSubview(field)
                cell.imageView = image
                cell.textField = field
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 18),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            let isMarker = item.version?.isDeleteMarker == true
            let symbol = isMarker ? "trash.slash" : Theme.symbol(forKey: item.key, isFolder: item.isFolder)
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            cell.imageView?.contentTintColor = isMarker ? .systemOrange : Theme.nsColor(forKey: item.key, isFolder: item.isFolder)
            cell.textField?.stringValue = item.name
            cell.textField?.font = item.isFolder ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 13)
            cell.textField?.textColor = isMarker ? .secondaryLabelColor : .labelColor
            cell.toolTip = item.key
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            parent.rows.indices.contains(row) ? parent.rows[row].name : nil
        }

        // MARK: Selection, sorting, paging

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let tableView else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { parent.rows.indices.contains($0) ? parent.rows[$0].id : nil })
            parent.actions.selectionChanged(ids)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
                  let column = ListingSortColumn(rawValue: key) else { return }
            parent.actions.sort(column, descriptor.ascending)
        }

        func observeScrolling(_ scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            // Selector-based observers are removed automatically when the coordinator is deallocated.
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification,
                                                   object: scrollView.contentView)
        }

        @objc private func boundsChanged(_ notification: Notification) { checkNearEnd() }

        func checkNearEnd() {
            guard let tableView, !parent.rows.isEmpty else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            let lastVisible = visible.location + visible.length
            guard lastVisible >= parent.rows.count - 200, parent.rows.count != lastNearEndRequest else { return }
            lastNearEndRequest = parent.rows.count
            parent.actions.nearEnd()
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard parent.rows.indices.contains(row) else { return }
            parent.actions.open(parent.rows[row])
        }

        var targetRows: [ListingRow] {
            guard let tableView else { return [] }
            let clicked = tableView.clickedRow
            if clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) {
                return parent.rows.indices.contains(clicked) ? [parent.rows[clicked]] : []
            }
            return tableView.selectedRowIndexes.compactMap { parent.rows.indices.contains($0) ? parent.rows[$0] : nil }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let built = parent.actions.menu(targetRows) else { return }
            for item in built.items {
                built.removeItem(item)
                menu.addItem(item)
            }
        }

        func openSelection() {
            guard let row = targetRows.first else { return }
            parent.actions.open(row)
        }

        func deleteSelection() {
            let rows = targetRows
            if !rows.isEmpty { parent.actions.delete(rows) }
        }

        func quickLookSelection() {
            if let row = targetRows.first, !row.isFolder { parent.actions.quickLook(row) }
        }

        // MARK: Drops from Finder

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard parent.acceptsDrops, info.draggingSource as? NSTableView !== tableView else { return [] }
            if dropOperation == .on, parent.rows.indices.contains(row), parent.rows[row].isFolder { return .copy }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !urls.isEmpty else { return false }
            let folder = dropOperation == .on && parent.rows.indices.contains(row) && parent.rows[row].isFolder ? parent.rows[row].key : nil
            parent.actions.dropFiles(urls, folder)
            return true
        }
    }
}

final class ObjectTableView: NSTableView {
    weak var coordinator: ObjectTable.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: coordinator?.openSelection() // Return, Enter
        case 49: coordinator?.quickLookSelection() // Space
        case 51 where event.modifierFlags.contains(.command), 117: coordinator?.deleteSelection() // ⌘⌫, forward delete
        default: super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        guard let coordinator else { return }
        let keys = coordinator.targetRows.map(\.key)
        guard !keys.isEmpty else { return }
        Pasteboard.copy(keys.joined(separator: "\n"))
    }
}
