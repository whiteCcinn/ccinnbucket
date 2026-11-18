import AppKit
import CcinnBucketKit
import StorageKit
import SwiftUI
import UniformTypeIdentifiers

/// Export or import of all connections (File ▸ Export Connections…, Import Connections…, the account screen).
enum ConnectionTransferRequest: Identifiable {
    case export
    case `import`(URL)

    var id: String {
        switch self {
        case .export: "export"
        case let .import(url): "import-" + url.path
        }
    }

    /// Asks for an export file to import; `nil` when cancelled.
    @MainActor
    static func chooseImportFile() -> ConnectionTransferRequest? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: ConnectionTransfer.fileExtension) ?? .json, .json]
        panel.prompt = "Import"
        panel.message = "Choose a CcinnBucket connections file (.\(ConnectionTransfer.fileExtension)) exported on another Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return .import(url)
    }
}

/// App preferences that travel with an export: a fixed list, each value checked before it is applied.
@MainActor
enum PortablePreferences {
    private enum Kind: Sendable {
        case string(isValid: @Sendable (String) -> Bool)
        case bool
    }

    private static let entries: [(key: String, kind: Kind)] = [
        ("appearance", .string { AppearancePreference(rawValue: $0) != nil }),
        (BrowserViewStyle.defaultsKey, .string { BrowserViewStyle(rawValue: $0) != nil }),
        (UpdateController.automaticCheckKey, .bool),
    ]

    static func collect(from defaults: UserDefaults = .standard) -> [String: String] {
        var values: [String: String] = [:]
        for entry in entries {
            guard let value = defaults.object(forKey: entry.key) else { continue }
            switch entry.kind {
            case .string: if let text = value as? String { values[entry.key] = text }
            case .bool: if let flag = value as? Bool { values[entry.key] = flag ? "true" : "false" }
            }
        }
        return values
    }

    /// Applies known keys with valid values; everything else in the file is ignored.
    @discardableResult
    static func apply(_ values: [String: String], to defaults: UserDefaults = .standard) -> Int {
        var applied = 0
        for entry in entries {
            guard let value = values[entry.key] else { continue }
            switch entry.kind {
            case let .string(isValid):
                guard isValid(value) else { continue }
                defaults.set(value, forKey: entry.key)
            case .bool:
                guard value == "true" || value == "false" else { continue }
                defaults.set(value == "true", forKey: entry.key)
            }
            applied += 1
        }
        return applied
    }
}

// MARK: - Export

struct ExportConnectionsSheet: View {
    let store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var includesSecrets = true
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var problem: String?
    @State private var exportedTo: URL?

    private var accounts: [StorageAccount] {
        store.accounts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var passphraseProblem: String? {
        guard includesSecrets else { return nil }
        if passphrase.count < ConnectionTransfer.minimumPassphraseLength {
            return "Use at least \(ConnectionTransfer.minimumPassphraseLength) characters."
        }
        if passphrase != confirmation { return "The passphrases do not match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Export Connections", systemImage: "square.and.arrow.up").font(.title3.weight(.semibold))
            if let exportedTo {
                exported(exportedTo)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    @ViewBuilder
    private var form: some View {
        Text("Saves all \(accounts.count) connection\(accounts.count == 1 ? "" : "s") — endpoints, regions, access key IDs, OSS options, colours, favourites, read-only and AI access settings — plus app preferences, to one file you can import on another Mac.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(accounts) { account in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.color(for: account.color)).frame(width: 8, height: 8)
                        Text(account.displayName).lineLimit(1)
                        Text(account.kind.displayName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        Toggle("Include secret keys, encrypted with a passphrase", isOn: $includesSecrets)
        if includesSecrets {
            SecureField("Passphrase (at least \(ConnectionTransfer.minimumPassphraseLength) characters)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("Repeat the passphrase", text: $confirmation)
                .textFieldStyle(.roundedBorder)
            Text("Secrets are encrypted with AES-256-GCM using a key derived from the passphrase (PBKDF2-SHA256, 600,000 rounds). Keep the passphrase separate from the file: together they give access to your storage.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !passphrase.isEmpty || !confirmation.isEmpty, let passphraseProblem {
                Text(passphraseProblem).font(.caption).foregroundStyle(.orange)
            }
        } else {
            Text("Secret keys stay in this Mac's Keychain; you will enter them again after importing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let problem { ErrorBanner(message: problem) }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                export()
            } label: {
                if working { ProgressView().controlSize(.small) } else { Text("Export…") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(accounts.isEmpty || passphraseProblem != nil || working)
        }
    }

    private func exported(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Exported \(accounts.count) connection\(accounts.count == 1 ? "" : "s")\(includesSecrets ? " with encrypted secret keys" : "").",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("On the new Mac, choose File ▸ Import Connections… (or Import Connections on the welcome screen) and pick this file.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ConnectionTransfer.fileExtension) ?? .json]
        // Today's date where the user is (ISO 8601 defaults to UTC, which can be yesterday or tomorrow).
        let today = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        panel.nameFieldStringValue = "CcinnBucket Connections \(today).\(ConnectionTransfer.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accounts = accounts
        var secrets: [UUID: ConnectionTransfer.Secrets] = [:]
        if includesSecrets {
            for account in accounts {
                let secret = store.secretAccessKey(for: account)
                let token = store.sessionToken(for: account)
                if secret != nil || token != nil { secrets[account.id] = .init(secretAccessKey: secret, sessionToken: token) }
            }
        }
        let passphrase = includesSecrets ? passphrase : nil
        let preferences = PortablePreferences.collect()
        let exportedSecrets = secrets
        let version = AppInfo.version
        working = true
        problem = nil
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try ConnectionTransfer.export(accounts, secrets: exportedSecrets, passphrase: passphrase, preferences: preferences,
                                                  appVersion: version)
                }.value
                try data.write(to: url, options: [.atomic])
                // The file can contain encrypted secrets and always lists access key IDs: owner-only.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                exportedTo = url
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? describe(error)
            }
            working = false
        }
    }
}

// MARK: - Import

struct ImportConnectionsSheet: View {
    let store: AccountStore
    let url: URL
    /// Called with the imported accounts (to select one).
    var onImported: ([StorageAccount]) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var file: ConnectionExport?
    @State private var unlocked: UnlockedConnections?
    @State private var plan: ConnectionTransfer.ImportPlan?
    @State private var passphrase = ""
    @State private var appliesPreferences = true
    @State private var appliesSensitiveUpdates = false
    @State private var working = false
    @State private var problem: String?
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import Connections", systemImage: "square.and.arrow.down").font(.title3.weight(.semibold))
            if let result {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else if let file, let unlocked, let plan {
                summary(file, unlocked, plan)
            } else if let file, file.isEncrypted {
                unlockForm(file)
            } else if let problem {
                ErrorBanner(message: problem)
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 540)
        .task(id: url) { read() }
    }

    private func header(_ file: ConnectionExport) -> some View {
        Text("\(url.lastPathComponent) · \(file.connectionCount) connection\(file.connectionCount == 1 ? "" : "s") · exported \(file.exportedAt.formatted(date: .abbreviated, time: .shortened)) by CcinnBucket \(file.appVersion)")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func unlockForm(_ file: ConnectionExport) -> some View {
        header(file)
        Text("This file is protected by a passphrase: the connections and their secret keys are encrypted.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        SecureField("Passphrase used for the export", text: $passphrase)
            .textFieldStyle(.roundedBorder)
            .onSubmit(unlock)
        if let problem { ErrorBanner(message: problem) }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                unlock()
            } label: {
                if working { ProgressView().controlSize(.small) } else { Text("Unlock") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(passphrase.isEmpty || working)
        }
    }

    @ViewBuilder
    private func summary(_ file: ConnectionExport, _ unlocked: UnlockedConnections, _ plan: ConnectionTransfer.ImportPlan) -> some View {
        header(file)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan.added) { row($0, label: "New", systemImage: "plus.circle.fill", color: .green) }
                ForEach(plan.updated, id: \.account.id) { update in
                    VStack(alignment: .leading, spacing: 1) {
                        row(update.account, label: "Update", systemImage: update.isSensitive ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill",
                            color: update.isSensitive ? .orange : .blue)
                        Text("Changes: \(update.changes.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary).padding(.leading, 22)
                    }
                }
                ForEach(plan.skipped) { row($0, label: "Already here", systemImage: "equal.circle.fill", color: .secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
        let sensitive = plan.updated.filter(\.isSensitive).count
        if sensitive > 0 {
            Toggle("Apply \(sensitive) change\(sensitive == 1 ? "" : "s") that redirect\(sensitive == 1 ? "s" : "") a connection or widen its access (endpoint, keys, read-only, AI access)",
                   isOn: $appliesSensitiveUpdates)
            if !file.isEncrypted {
                Text("This file has no passphrase, so anyone could have changed it. Leave this off unless you made these changes; the saved connections keep their secret keys.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        let aiEnabled = (plan.added + plan.updated.map(\.account)).filter { $0.mcpAccess != .disabled }.count
        if aiEnabled > 0 {
            NoticeBanner(message: "\(aiEnabled) connection\(aiEnabled == 1 ? "" : "s") allow AI access via MCP. Review them in Settings → MCP after importing.",
                         systemImage: "sparkles")
        }
        if file.isEncrypted {
            Text("Secret keys are saved to this Mac's Keychain. Updated connections keep their current secret if the file has none for them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("This file has no secret keys: enter each secret access key after importing (Edit the connection).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if !unlocked.preferences.isEmpty {
            Toggle("Also apply preferences (appearance, list or columns, update checks)", isOn: $appliesPreferences)
        }
        if let problem { ErrorBanner(message: problem) }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                importNow()
            } label: {
                if working { ProgressView().controlSize(.small) } else { Text(importTitle(plan)) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(working || importCount(plan) == 0 && !(appliesPreferences && !unlocked.preferences.isEmpty))
        }
    }

    private func row(_ account: StorageAccount, label: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(account.displayName).lineLimit(1)
            Text("\(account.kind.displayName) · \(account.effectiveEndpointDescription)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func importCount(_ plan: ConnectionTransfer.ImportPlan) -> Int {
        plan.added.count + plan.updated.filter { appliesSensitiveUpdates || !$0.isSensitive }.count
    }

    private func importTitle(_ plan: ConnectionTransfer.ImportPlan) -> String {
        let count = importCount(plan)
        return count == 0 ? "Import" : "Import \(count) Connection\(count == 1 ? "" : "s")"
    }

    private func read() {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let file = try ConnectionTransfer.read(data)
            self.file = file
            if !file.isEncrypted { show(try ConnectionTransfer.unlock(file, passphrase: nil), encrypted: false) }
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? describe(error)
        }
    }

    private func show(_ content: UnlockedConnections, encrypted: Bool) {
        unlocked = content
        plan = ConnectionTransfer.plan(content.accounts, existing: store.accounts)
        // A sealed file was made by someone who knows the passphrase; a plain file could have been edited by anyone.
        appliesSensitiveUpdates = encrypted
        problem = nil
    }

    private func unlock() {
        guard let file, !working, !passphrase.isEmpty else { return }
        let passphrase = passphrase
        working = true
        problem = nil
        Task {
            do {
                let content = try await Task.detached(priority: .userInitiated) { try ConnectionTransfer.unlock(file, passphrase: passphrase) }.value
                show(content, encrypted: true)
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? describe(error)
            }
            working = false
        }
    }

    private func importNow() {
        guard let unlocked, let plan, !working else { return }
        working = true
        problem = nil
        do {
            let imported = try store.importConnections(plan, secrets: unlocked.secrets, applyingSensitiveUpdates: appliesSensitiveUpdates)
            let preferences = appliesPreferences ? PortablePreferences.apply(unlocked.preferences) : 0
            let savedSecrets = unlocked.secrets.keys.filter { id in imported.contains { $0.id == id } }.count
            var parts = ["Imported \(imported.count) connection\(imported.count == 1 ? "" : "s")"]
            let left = plan.skipped.count + plan.updated.filter { $0.isSensitive && !appliesSensitiveUpdates }.count
            if left > 0 { parts.append("\(left) left as they were") }
            if savedSecrets > 0 { parts.append("\(savedSecrets) secret key\(savedSecrets == 1 ? "" : "s") saved to the Keychain") }
            if preferences > 0 { parts.append("preferences applied") }
            result = parts.joined(separator: " · ") + "."
            onImported(imported)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? describe(error)
        }
        working = false
    }
}
