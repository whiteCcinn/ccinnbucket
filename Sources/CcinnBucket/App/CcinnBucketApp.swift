import AppKit
import CcinnBucketKit
import StorageKit
import StorageSigning
import SwiftUI

struct CcinnBucketApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        WindowGroup("CcinnBucket", id: "main") {
            RootView()
                .frame(minWidth: 1080, minHeight: 660)
                .preferredColorScheme(LaunchArguments.appearanceOverride ?? AppearancePreference(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .frame(width: 640, height: 560)
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Behave like a regular app when launched from `swift run` (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
        if let scheme = LaunchArguments.appearanceOverride {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        }
        PreviewLoader.cleanUp()
        SnapshotTool.scheduleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        PreviewLoader.cleanUp()
    }
}

/// Per-window root: account manager, progress, or workspace.
struct RootView: View {
    @State private var session = WindowSession()
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
        .focusedSceneValue(\.windowSession, session)
        .navigationTitle(windowTitle)
        .onDisappear { session.disconnect() }
        .task { LaunchArguments.consume(into: session, store: store) }
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
///                 [--bucket b] [--prefix p/] [--select key] [--versions] [--sort size|modified] [--load-all]
///                 [--settings versioning|lifecycle|cors|policy|acl|encryption|uploads] [--transfers] [--upload /path/file]
///                 [--preview] [--edit-metadata] [--confirm-delete] [--share] [--hide-inspector]
///     CcinnBucket --data-dir /tmp/demo --demo-accounts [--new-account minio|oss|…]
///     … [--appearance light|dark] [--snapshot out.png --snapshot-delay 6 --quit-after-snapshot]
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

    static func consume(into session: WindowSession, store: AccountStore) {
        guard !consumed else { return }
        consumed = true
        if has("--demo-accounts") { seedDemoAccounts(store) }

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
        guard let account else { return }
        session.connect(account: account, store: store, overrideCredentials: credentials) { workspace in
            Task { @MainActor in await applyDeepLink(to: workspace) }
        }
    }

    private static func applyDeepLink(to workspace: WorkspaceModel) async {
        if has("--hide-inspector") { workspace.showInspector = false }
        if let bucket = value("--bucket") ?? (workspace.account.defaultBucket.isEmpty ? nil : workspace.account.defaultBucket) {
            workspace.open(bucket: bucket, prefix: value("--prefix") ?? "")
        }
        guard let browser = workspace.browser else { return }
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

    private static func waitUntil(timeout: TimeInterval = 20, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Sample accounts for the account-manager screenshot (isolated `--data-dir` only).
    private static func seedDemoAccounts(_ store: AccountStore) {
        guard value("--data-dir") != nil, store.accounts.isEmpty else { return }
        var minio = StorageAccount(kind: .minio, name: "Local MinIO", accessKeyID: value("--access-key") ?? "ccinnbucket", color: .cyan)
        minio.endpoint = value("--connect") ?? "http://127.0.0.1:19900"
        minio.isFavorite = true
        minio.lastConnectedAt = Date()
        var aws = StorageAccount(kind: .amazonS3, name: "Production (S3)", accessKeyID: "AKIAIOSFODNN7EXAMPLE", color: .orange)
        aws.region = "eu-central-1"
        aws.isReadOnly = true
        aws.lastConnectedAt = Date().addingTimeInterval(-3_600)
        var oss = StorageAccount(kind: .alibabaOSS, name: "Media (OSS Hangzhou)", accessKeyID: "LTAI5tEXAMPLEaccessKey", color: .pink)
        oss.region = "cn-hangzhou"
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

    static func take() -> BucketSettingsView.Tab? {
        defer { tab = nil }
        return tab
    }
}

/// `--snapshot <file.png> [--snapshot-delay seconds] [--quit-after-snapshot]`: renders the key window (and an
/// attached sheet, composited on top) into a PNG. Needs no screen-recording permission.
@MainActor
enum SnapshotTool {
    static func scheduleIfRequested() {
        guard let path = LaunchArguments.value("--snapshot") else { return }
        let delay = LaunchArguments.value("--snapshot-delay").flatMap(Double.init) ?? 6
        let quit = LaunchArguments.has("--quit-after-snapshot")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.frame.width > 400 }),
               let data = render(window) {
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
        overlay.draw(in: NSRect(origin: origin, size: sheetView.bounds.size))
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
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            MCPSettingsView(store: AppServices.shared.accounts)
                .tabItem { Label("MCP", systemImage: "sparkles") }
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
                Text("CcinnBucket includes a Model Context Protocol server, so AI tools such as Claude Code, Codex and Claude Desktop can list buckets and read objects through your saved accounts. Accounts are off until you enable them below; read-only is the safe default. Every call is logged to mcp-audit.jsonl in the accounts folder.")
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
                        _ = try? store.save(updated, secretAccessKey: store.secretAccessKey(for: account), sessionToken: store.sessionToken(for: account))
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

    private var workspace: WorkspaceModel? { session?.workspace }
    private var browser: BrowserModel? { session?.workspace?.browser }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace == nil)
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
            Button("New Folder…") { browser?.sheet = .newFolder }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser == nil || workspace?.isReadOnly == true)
            Button("Download…") { if let browser { browser.chooseDownloadDestination(for: browser.selectedRows) } }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(browser?.selection.isEmpty ?? true)
            Button("Delete…") { if let browser { browser.requestDelete(browser.selectedRows) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled((browser?.selection.isEmpty ?? true) || workspace?.isReadOnly == true)
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
