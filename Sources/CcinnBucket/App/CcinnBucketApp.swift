import AppKit
import CcinnBucketKit
import StorageKit
import StorageSigning
import SwiftUI

struct CcinnBucketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        // Every window has its own connection. A request opens a window that connects right away.
        WindowGroup("CcinnBucket", id: RootView.windowGroupID, for: WindowRequest.self) { $request in
            RootView(request: request)
                .frame(minWidth: 1080, minHeight: 660)
                .preferredColorScheme(LaunchArguments.appearanceOverride ?? AppearancePreference(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands()
            UpdateCommands()
        }

        Settings {
            SettingsView()
                .frame(width: 640, height: 560)
                .tint(Theme.accent)
        }

        SoftwareUpdateScene()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Restored windows would only reopen the account screen; start with one clean window.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotTool.isRequested, !LaunchArguments.has("--snapshot-visible") {
            // Visual checks run invisibly: no Dock icon, no focus stealing, transparent windows.
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Behave like a regular app when launched from `swift run` (no bundle).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        if let scheme = LaunchArguments.appearanceOverride {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        }
        PreviewLoader.cleanUp()
        SnapshotTool.scheduleIfRequested()
        UpdateController.shared.scheduleAutomaticCheck()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        PreviewLoader.cleanUp()
    }
}

/// Per-window root: account manager, progress, or workspace.
struct RootView: View {
    static let windowGroupID = "main"

    /// Set when the window was opened for an account (Open in New Window, New Window with This Connection).
    let request: WindowRequest?
    @State private var session = WindowSession(handoff: AppServices.shared.windowHandoff)
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    private let store = AppServices.shared.accounts

    var body: some View {
        Group {
            switch session.phase {
            case .accounts:
                AccountsView(session: session, store: store)
                    .transition(.opacity)
            case let .connecting(name):
                ConnectingView(name: name) { session.cancelConnecting() }
                    .transition(.opacity)
            case let .connected(workspace):
                WorkspaceView(workspace: workspace, session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .sheet(item: $session.connectionTransfer) { request in
            switch request {
            case .export: ExportConnectionsSheet(store: store)
            case let .import(url): ImportConnectionsSheet(store: store, url: url)
            }
        }
        .focusedSceneValue(\.windowSession, session)
        .navigationTitle(windowTitle)
        .presentsSoftwareUpdates()
        .onDisappear { session.disconnect() }
        .task {
            if let request, session.connect(request, store: store) { return }
            // A window without a request, or one macOS restored (its request has no handoff): launch arguments apply to
            // the first such window only; later ones start at the account screen.
            guard LaunchArguments.consume(into: session, store: store, openWindow: { openWindow(id: Self.windowGroupID, value: $0) }) else { return }
            if let pane = LaunchArguments.value("--open-settings") {
                SettingsDeepLink.pane = pane
                try? await Task.sleep(nanoseconds: 800_000_000)
                openSettings()
            }
        }
    }

    private var phaseKey: Int {
        switch session.phase {
        case .accounts: 0
        case .connecting: 1
        case .connected: 2
        }
    }

    private var windowTitle: String {
        switch session.phase {
        case .accounts: "CcinnBucket — Accounts"
        case let .connecting(name): "Connecting to \(name)"
        case let .connected(workspace): workspace.browser.map { "\($0.bucket)/\($0.prefix)" } ?? workspace.account.displayName
        }
    }
}

/// Full-window progress while an account is being opened.
struct ConnectingView: View {
    let name: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 64).symbolEffect(.pulse)
            Text("Connecting to \(name)").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Listing buckets…").foregroundStyle(.secondary)
            }
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Developer conveniences, deep links and automated visual checks.
///
///     CcinnBucket --account <saved name>
///     CcinnBucket --connect http://127.0.0.1:19900 --access-key AK --secret-key SK [--kind minio] [--region r] [--name n] [--read-only]
///                 [--bucket b] [--prefix p/] [--select key] [--view list|columns] [--versions] [--sort size|modified] [--load-all]
///                 [--settings versioning|lifecycle|cors|policy|acl|encryption|uploads] [--transfers] [--upload /path/file]
///                 [--preview] [--edit-metadata] [--confirm-delete] [--share] [--hide-inspector]
///     CcinnBucket --data-dir /tmp/demo --demo-accounts [--new-account minio|oss|…] [--export-connections] [--import-connections file]
///     … [--duplicate-window] [--appearance light|dark] [--snapshot out.png --snapshot-delay 6 --quit-after-snapshot [--snapshot-window title]]
///
/// Secrets passed on the command line live only in memory and are never saved.
@MainActor
enum LaunchArguments {
    private static var consumed = false

    nonisolated static var arguments: [String] { ProcessInfo.processInfo.arguments }

    nonisolated static func value(_ flag: String) -> String? {
        let arguments = arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    nonisolated static func has(_ flag: String) -> Bool { arguments.contains(flag) }

    nonisolated static var appearanceOverride: ColorScheme? {
        switch value("--appearance")?.lowercased() {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// Applies the launch arguments to the first window that asks; returns `false` for every later window.
    /// - Parameter openWindow: opens another window for `--duplicate-window`.
    static func consume(into session: WindowSession, store: AccountStore, openWindow: @escaping @MainActor (WindowRequest) -> Void) -> Bool {
        guard !consumed else { return false }
        consumed = true
        if has("--demo-accounts") { seedDemoAccounts(store) }
        if has("--export-connections") { session.connectionTransfer = .export }
        if let path = value("--import-connections") { session.connectionTransfer = .import(URL(fileURLWithPath: path)) }

        var account: StorageAccount?
        var credentials: SigningCredentials?
        if let name = value("--account") {
            account = store.accounts.first { $0.displayName == name }
        } else if let endpoint = value("--connect") {
            let kind = value("--kind").flatMap { raw in AccountKind.allCases.first { $0.rawValue.lowercased() == raw.lowercased() } } ?? .minio
            var ephemeral = StorageAccount(kind: kind, name: value("--name") ?? (StorageEndpoint(string: endpoint)?.host ?? endpoint),
                                           accessKeyID: value("--access-key") ?? "", color: .cyan)
            ephemeral.endpoint = endpoint
            if let region = value("--region") { ephemeral.region = region }
            ephemeral.isReadOnly = has("--read-only")
            account = ephemeral
            credentials = SigningCredentials(accessKeyID: ephemeral.accessKeyID, secretAccessKey: value("--secret-key") ?? "")
        }
        guard let account else { return true }
        session.connect(account: account, store: store, overrideCredentials: credentials) { [weak session] workspace in
            if has("--duplicate-window"), let request = session?.duplicateRequest() { openWindow(request) }
            Task { @MainActor in await applyDeepLink(to: workspace) }
        }
        return true
    }

    private static func applyDeepLink(to workspace: WorkspaceModel) async {
        if has("--hide-inspector") { workspace.showInspector = false }
        if let bucket = value("--bucket") ?? (workspace.account.defaultBucket.isEmpty ? nil : workspace.account.defaultBucket) {
            workspace.open(bucket: bucket, prefix: value("--prefix") ?? "")
        }
        guard let browser = workspace.browser else { return }
        if let style = value("--view").flatMap(BrowserViewStyle.init(rawValue:)) { browser.setViewStyle(style, remember: false) }
        if has("--versions") { browser.setMode(.versions) }
        await waitUntil { !browser.isLoading }
        if let sort = value("--sort") {
            switch sort {
            case "size": browser.setSort(.size, ascending: false)
            case "modified": browser.setSort(.modified, ascending: false)
            default: break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if has("--load-all") { browser.loadAll() }
        if let key = value("--select") {
            await waitUntil { browser.rows.contains { $0.key == key || $0.key == key + "/" } }
            browser.select(key: key)
            await waitUntil { browser.inspector?.metadata != nil || browser.selection.isEmpty }
            if has("--edit-metadata") {
                await waitUntil { browser.inspector?.tags != nil }
                browser.inspector?.beginEditing()
            }
            if has("--preview"), let row = browser.selectedRows.first { browser.sheet = .preview(row) }
            if has("--share"), let row = browser.selectedRows.first { browser.sheet = .presign(row) }
            if has("--confirm-delete") { browser.requestDelete(browser.selectedRows) }
        }
        if let raw = value("--settings") {
            workspace.settingsBucket = browser.bucket
            SettingsDeepLink.tab = BucketSettingsView.Tab.allCases.first { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }
                ?? (raw.lowercased() == "uploads" ? .uploads : .versioning)
        }
        if let path = value("--upload") {
            browser.upload([URL(fileURLWithPath: path)])
            workspace.showTransfers = true
        }
        if has("--transfers") { workspace.showTransfers = true }
    }

    private static func waitUntil(timeout: TimeInterval = 60, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Sample accounts for the account-manager screenshot (isolated `--data-dir` only).
    private static func seedDemoAccounts(_ store: AccountStore) {
        guard value("--data-dir") != nil, store.accounts.isEmpty else { return }
        var minio = StorageAccount(kind: .minio, name: "Local MinIO", accessKeyID: value("--access-key") ?? "ccinnbucket", color: .cyan)
        minio.endpoint = value("--connect") ?? "http://127.0.0.1:19900"
        minio.isFavorite = true
        minio.mcpAccess = .readOnly
        minio.lastConnectedAt = Date()
        var aws = StorageAccount(kind: .amazonS3, name: "Production (S3)", accessKeyID: "AKIAIOSFODNN7EXAMPLE", color: .orange)
        aws.region = "eu-central-1"
        aws.isReadOnly = true
        aws.lastConnectedAt = Date().addingTimeInterval(-3_600)
        var oss = StorageAccount(kind: .alibabaOSS, name: "Media (OSS Hangzhou)", accessKeyID: "LTAI5tEXAMPLEaccessKey", color: .pink)
        oss.region = "cn-hangzhou"
        oss.mcpAccess = .readWrite
        var r2 = StorageAccount(kind: .cloudflareR2, name: "Assets (R2)", accessKeyID: "r2examplekey0123456789", color: .indigo)
        r2.endpoint = "https://0123456789abcdef.r2.cloudflarestorage.com"
        var archive = StorageAccount(kind: .wasabi, name: "Cold archive", accessKeyID: "WASABIEXAMPLEKEY", color: .green)
        archive.region = "eu-central-1"
        archive.endpoint = "https://s3.eu-central-1.wasabisys.com"
        for account in [minio, aws, oss, r2, archive] {
            _ = try? store.save(account, secretAccessKey: account.kind == .minio ? (value("--secret-key") ?? "demo") : "demo-secret", sessionToken: nil)
        }
    }
}

/// Initial tab for the settings sheet when opened from a deep link.
@MainActor
enum SettingsDeepLink {
    static var tab: BucketSettingsView.Tab?
    /// Settings pane to show first ("general" or "mcp").
    static var pane: String?

    static func take() -> BucketSettingsView.Tab? {
        defer { tab = nil }
        return tab
    }
}

/// `--snapshot <file.png> [--snapshot-delay seconds] [--quit-after-snapshot]`: renders the key window (and an
/// attached sheet, composited on top) into a PNG. Needs no screen-recording permission.
@MainActor
enum SnapshotTool {
    nonisolated static var isRequested: Bool { LaunchArguments.value("--snapshot") != nil }

    static func scheduleIfRequested() {
        guard let path = LaunchArguments.value("--snapshot") else { return }
        if !LaunchArguments.has("--snapshot-visible") {
            // Keep every window (and sheet) transparent so the check never disturbs the user; views still render.
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated { for window in NSApp.windows where window.alphaValue != 0 { window.alphaValue = 0 } }
            }
        }
        let delay = LaunchArguments.value("--snapshot-delay").flatMap(Double.init) ?? 6
        let quit = LaunchArguments.has("--quit-after-snapshot")
        let wantedTitle = LaunchArguments.value("--snapshot-window")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let candidates = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil && $0.frame.width > 400 }
            let chosen = wantedTitle.flatMap { title in candidates.first { $0.title.localizedCaseInsensitiveContains(title) } } ?? candidates.first
            if let window = chosen, let data = render(window) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            if quit { NSApp.terminate(nil) }
        }
    }

    private static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    static func render(_ window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView, let base = bitmap(of: view) else { return nil }
        guard let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
              let overlay = bitmap(of: sheetView) else {
            return base.representation(using: .png, properties: [:])
        }
        let size = view.bounds.size
        let composite = NSImage(size: size)
        composite.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        NSColor.black.withAlphaComponent(0.12).setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        let origin = NSPoint(x: sheet.frame.minX - window.frame.minX, y: sheet.frame.minY - window.frame.minY)
        let sheetRect = NSRect(origin: origin, size: sheetView.bounds.size)
        // Sheets are separate windows: give the composite their opaque background and shadow.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        var background = NSColor.windowBackgroundColor
        sheet.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor }
        background.setFill()
        NSBezierPath(roundedRect: sheetRect, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: sheetRect, xRadius: 10, yRadius: 10).addClip()
        overlay.draw(in: sheetRect)
        NSGraphicsContext.restoreGraphicsState()
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @State private var pane = SettingsDeepLink.pane == "mcp" ? "mcp" : "general"

    var body: some View {
        TabView(selection: $pane) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            MCPSettingsView(store: AppServices.shared.accounts)
                .tabItem { Label("MCP", systemImage: "sparkles") }
                .tag("mcp")
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            LabeledContent("Saved accounts") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AccountRepository.defaultDirectory])
                }
            }
            LabeledContent("Preview cache") {
                Button("Clear") { PreviewLoader.cleanUp() }
            }
            Text("Secrets are stored in the macOS Keychain under “io.github.whiteccinn.ccinnbucket.accounts”. Part size and read-only mode are set per account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            UpdateSettingsSections()
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

/// Settings → MCP: explains AI access, edits per-account access and offers copyable client configuration.
struct MCPSettingsView: View {
    let store: AccountStore
    @State private var copied: String?

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? "/Applications/CcinnBucket.app/Contents/MacOS/CcinnBucket"
    }

    private var snippets: [(title: String, text: String)] {
        let path = Self.executablePath
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return [
            ("Claude Code", "claude mcp add ccinnbucket -- \"\(path)\" mcp"),
            ("Codex (~/.codex/config.toml)", "[mcp_servers.ccinnbucket]\ncommand = \"\(escaped)\"\nargs = [\"mcp\"]"),
            ("Claude Desktop / JSON", "{\n  \"mcpServers\": {\n    \"ccinnbucket\": {\n      \"command\": \"\(escaped)\",\n      \"args\": [\"mcp\"]\n    }\n  }\n}"),
        ]
    }

    var body: some View {
        Form {
            Section {
                Text("CcinnBucket includes a Model Context Protocol server, so AI tools such as Claude Code, Codex and Claude Desktop can list buckets and read objects through your saved accounts. Accounts are off until you enable them below; read-only is the safe default. Every call is logged to mcp-audit.jsonl in the accounts folder. Changes apply to running AI clients immediately.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Accounts") {
                if store.accounts.isEmpty {
                    Text("No saved accounts yet.").foregroundStyle(.secondary)
                }
                ForEach(store.accounts) { account in
                    Picker(selection: Binding(get: { account.mcpAccess }, set: { access in
                        var updated = account
                        updated.mcpAccess = access
                        store.update(updated)
                    })) {
                        ForEach(MCPAccess.allCases) { Text($0.title).tag($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.displayName)
                            Text(account.isReadOnly ? "Read-only account (AI access capped at read-only)" : account.summary)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Section("Connect an AI client") {
                ForEach(snippets, id: \.title) { snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(snippet.title).font(.callout.weight(.medium))
                            Spacer()
                            Button(copied == snippet.title ? "Copied" : "Copy") {
                                Pasteboard.copy(snippet.text)
                                copied = snippet.title
                            }
                        }
                        Text(snippet.text)
                            .font(Theme.monospacedSmall)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
                    }
                }
                Text("Add --read-only after mcp to cap every account at read-only, or --profile \"<account>\" to pick a default account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Commands

struct WindowSessionKey: FocusedValueKey {
    typealias Value = WindowSession
}

extension FocusedValues {
    var windowSession: WindowSession? {
        get { self[WindowSessionKey.self] }
        set { self[WindowSessionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowSession) private var session
    @Environment(\.openWindow) private var openWindow

    /// A sheet or dialog is open in the focused window. Window commands are then disabled: their shortcuts (⌘↑, ⌘⌫,
    /// ⌘R, ⌘[ …) would otherwise act on the browser behind the sheet and steal keys from a text editor in it (⌘↑
    /// moved to the enclosing folder, ⌘⌫ asked to delete the selected object).
    private var isModalOpen: Bool {
        guard let session else { return false }
        if session.connectionTransfer != nil { return true }
        guard let workspace = session.workspace else { return false }
        if workspace.isCreatingBucket || workspace.settingsBucket != nil { return true }
        guard let browser = workspace.browser else { return false }
        return browser.sheet != nil || browser.pendingDelete != nil || browser.pendingUploadConflict != nil
    }

    private var workspace: WorkspaceModel? { isModalOpen ? nil : session?.workspace }
    private var browser: BrowserModel? { isModalOpen ? nil : session?.workspace?.browser }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // File ▸ New Window (⌘N) comes from the window group and opens the account screen.
            // ⇧⌘N is New Folder, so duplicating the connection uses ⌥⌘N.
            Button("New Window with This Connection") {
                if let request = session?.duplicateRequest() { openWindow(id: RootView.windowGroupID, value: request) }
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(workspace == nil)
            Divider()
            Button("Export Connections…") { session?.connectionTransfer = .export }
                .disabled(session == nil || isModalOpen || AppServices.shared.accounts.accounts.isEmpty)
            Button("Import Connections…") {
                if let request = ConnectionTransferRequest.chooseImportFile() { session?.connectionTransfer = request }
            }
            .disabled(session == nil || isModalOpen)
            Divider()
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace == nil)
        }
        CommandGroup(before: .toolbar) {
            Toggle("as List", isOn: Binding(get: { browser?.effectiveViewStyle == .list }, set: { if $0 { browser?.setViewStyle(.list) } }))
                .keyboardShortcut("2", modifiers: .command)
                .disabled(browser == nil || browser?.mode == .versions)
            Toggle("as Columns", isOn: Binding(get: { browser?.effectiveViewStyle == .columns }, set: { if $0 { browser?.setViewStyle(.columns) } }))
                .keyboardShortcut("3", modifiers: .command)
                .disabled(browser == nil || browser?.mode == .versions)
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!(browser?.canGoBack ?? false))
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!(browser?.canGoForward ?? false))
            Button("Enclosing Folder") { browser?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!(browser?.canGoUp ?? false))
            Divider()
            Button("Refresh") { browser?.reload() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(browser == nil)
            Button("Load All Pages") { browser?.loadAll() }
                .disabled(!(browser?.hasMore ?? false))
        }
        CommandMenu("Object") {
            Button("Upload…") { if let browser { UploadPanel.run(model: browser) } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(browser == nil || workspace?.isReadOnly == true)
            Button("New Folder…") { if let browser { browser.sheet = .newFolder(parent: browser.prefix) } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser == nil || workspace?.isReadOnly == true)
            Button("Download…") { if let browser { browser.chooseDownloadDestination(for: browser.actionRows) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(browser?.actionRows.isEmpty ?? true)
            Button("Delete…") { if let browser { browser.requestDelete(browser.actionRows) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled((browser?.actionRows.isEmpty ?? true) || workspace?.isReadOnly == true)
            Divider()
            Button("Show Versions") { browser?.setMode(browser?.mode == .versions ? .objects : .versions) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(browser == nil)
            Button("Inspector") { workspace?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Button("Transfers") { workspace?.showTransfers.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Button("Bucket Settings…") { if let bucket = browser?.bucket { workspace?.settingsBucket = bucket } }
                .keyboardShortcut(",", modifiers: [.command, .option])
                .disabled(browser == nil)
        }
    }
}
