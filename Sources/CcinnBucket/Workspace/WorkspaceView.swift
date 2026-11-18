import CcinnBucketKit
import StorageKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    let session: WindowSession
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            BucketSidebar(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if let browser = workspace.browser {
                        BrowserView(model: browser, workspace: workspace)
                            .id(browser.bucket)
                    } else {
                        WorkspaceHome(workspace: workspace)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if workspace.showTransfers {
                    Divider()
                    TransfersPanel(model: workspace.transfers) { withAnimation(.snappy) { workspace.showTransfers = false } }
                        .frame(height: 260)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) { ToastView(toast: workspace.toast).padding(.bottom, workspace.showTransfers ? 270 : 0) }
            .inspector(isPresented: $workspace.showInspector) {
                InspectorView(browser: workspace.browser)
                    .inspectorColumnWidth(min: 280, ideal: 330, max: 480)
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $workspace.isCreatingBucket) { CreateBucketSheet(workspace: workspace) }
        .sheet(item: Binding(get: { workspace.settingsBucket.map(IdentifiedBucket.init) }, set: { workspace.settingsBucket = $0?.name })) { item in
            BucketSettingsView(workspace: workspace, bucket: item.name, initialTab: SettingsDeepLink.take() ?? .versioning)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { workspace.browser?.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!(workspace.browser?.canGoBack ?? false))
                .help("Back (⌘[)")
            Button { workspace.browser?.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!(workspace.browser?.canGoForward ?? false))
                .help("Forward (⌘])")
            Button { workspace.browser?.goUp() } label: { Label("Enclosing Folder", systemImage: "arrow.turn.left.up") }
                .disabled(!(workspace.browser?.canGoUp ?? false))
                .help("Enclosing folder (⌘↑)")
        }
        ToolbarItem(placement: .navigation) {
            ViewStylePicker(browser: workspace.browser)
        }
        ToolbarItem(placement: .principal) {
            AccountBadge(workspace: workspace)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let browser = workspace.browser
            let selection = browser?.actionRows ?? []
            let writable = !workspace.isReadOnly && browser != nil
            Button { if let browser { UploadPanel.run(model: browser) } } label: { Label("Upload", systemImage: "arrow.up.doc") }
                .disabled(!writable)
                .help(workspace.isReadOnly ? "Read-only account" : "Upload files or folders (or drop them on the list)")
            Button { if let browser { browser.sheet = .newFolder(parent: browser.prefix) } } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .disabled(!writable)
                .help("New folder (⇧⌘N)")
            Button { browser?.chooseDownloadDestination(for: selection) } label: { Label("Download", systemImage: "arrow.down.circle") }
                .disabled(selection.isEmpty)
                .help("Download the selection")
            Button { if let row = selection.first { browser?.sheet = .presign(row) } } label: { Label("Share Link", systemImage: "link") }
                .disabled(selection.count != 1 || selection.first?.isFolder == true)
                .help("Create a presigned link")
            Button { browser?.requestDelete(selection) } label: { Label("Delete", systemImage: "trash") }
                .disabled(!writable || selection.isEmpty)
                .help("Delete the selection (⌘⌫)")
            Button { browser?.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(browser == nil)
                .help("Reload the listing (⌘R)")
            Button { if let bucket = browser?.bucket { workspace.settingsBucket = bucket } } label: { Label("Bucket Settings", systemImage: "gearshape") }
                .disabled(browser == nil)
                .help("Versioning, lifecycle, CORS, policy, ACL, encryption and incomplete uploads")
            Menu {
                Button("New Window with This Connection", action: openWindowWithThisConnection)
                Button("New Window") { openWindow(id: RootView.windowGroupID) }
            } label: {
                Label("New Window", systemImage: "macwindow.badge.plus")
            } primaryAction: {
                openWindowWithThisConnection()
            }
            .help("Open this connection in another window (⌥⌘N); each window has its own connection")
            TransfersToolbarButton(model: workspace.transfers) { withAnimation(.snappy) { workspace.showTransfers.toggle() } }
            Button { workspace.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }

    /// Another window connected to this account with the credentials in use (each window has its own connection).
    private func openWindowWithThisConnection() {
        if let request = session.duplicateRequest() { openWindow(id: RootView.windowGroupID, value: request) }
    }
}

/// List or columns, like Finder's view buttons (Versions always use the list).
private struct ViewStylePicker: View {
    let browser: BrowserModel?

    var body: some View {
        Picker("View", selection: Binding(get: { browser?.effectiveViewStyle ?? .list }, set: { browser?.setViewStyle($0) })) {
            Label("as List", systemImage: "list.bullet").tag(BrowserViewStyle.list)
            Label("as Columns", systemImage: "rectangle.split.3x1").tag(BrowserViewStyle.columns)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .disabled(browser == nil || browser?.mode == .versions)
        .help(browser?.mode == .versions ? "Versions are always shown as a list" : "Show items in a list (⌘2) or in columns (⌘3)")
    }
}

private struct IdentifiedBucket: Identifiable {
    let name: String
    var id: String { name }
}

private struct AccountBadge: View {
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.color(for: workspace.account.color).gradient)
                .frame(width: 9, height: 9)
            Image(systemName: workspace.account.kind.symbolName).foregroundStyle(.secondary)
            Text(workspace.account.displayName).font(.headline).lineLimit(1)
            if workspace.isReadOnly { Badge(text: "Read-only", color: .orange, systemImage: "lock.fill") }
        }
        .padding(.horizontal, 6)
        .help(workspace.account.summary)
    }
}

struct ToastView: View {
    let toast: Toast?

    var body: some View {
        Group {
            if let toast {
                Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .foregroundStyle(toast.isError ? Color.red : Color.primary)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .frame(maxWidth: 640)
            }
        }
        .padding(.bottom, 44)
        .animation(.spring(duration: 0.35), value: toast)
    }
}

/// Shown before a bucket is chosen.
private struct WorkspaceHome: View {
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 20) {
            AppLogo(size: 72)
            VStack(spacing: 6) {
                Text(workspace.account.displayName).font(.title.weight(.semibold))
                Text("\(workspace.account.kind.displayName) · \(workspace.account.effectiveEndpointDescription)")
                    .foregroundStyle(.secondary)
                Text("\(workspace.buckets.count.formatted()) bucket\(workspace.buckets.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            Text("Choose a bucket in the sidebar to browse it. Drop files on the list to upload.")
                .foregroundStyle(.secondary)
            if !workspace.isReadOnly {
                Button { workspace.isCreatingBucket = true } label: { Label("Create Bucket", systemImage: "plus") }
                    .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
