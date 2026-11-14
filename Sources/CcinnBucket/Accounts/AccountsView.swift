import AppKit
import CcinnBucketKit
import StorageKit
import SwiftUI

/// Account manager: saved accounts on the left, editor (or welcome) on the right.
struct AccountsView: View {
    @Bindable var session: WindowSession
    let store: AccountStore

    @State private var selection: UUID?
    @State private var draft: AccountDraft?
    @State private var search = ""
    @State private var pendingDelete: StorageAccount?
    @State private var showingImport = false

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
        }
        .onChange(of: selection) { _, newValue in
            if let account = store.account(id: newValue) { draft = AccountDraft(account: account, store: store) }
        }
        .onAppear {
            if draft == nil, let first = store.favorites.first ?? store.recents.first ?? store.others.first {
                selection = first.id
                draft = AccountDraft(account: first, store: store)
            }
        }
        .sheet(isPresented: $showingImport) {
            ImportCredentialsSheet(store: store) { imported in
                if let first = imported.first { selection = first.id }
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.displayName ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let account = pendingDelete {
                    store.delete(account)
                    if selection == account.id {
                        selection = nil
                        draft = nil
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("The saved account and its Keychain secrets will be removed. Objects in the storage service are not affected.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter accounts", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            List(selection: $selection) {
                if !store.favorites.isEmpty { Section("Favorites") { rows(filtered(store.favorites)) } }
                if !store.recents.isEmpty { Section("Recent") { rows(filtered(store.recents)) } }
                if !store.others.isEmpty { Section("Saved") { rows(filtered(store.others)) } }
            }
            .listStyle(.sidebar)
            .overlay {
                if store.accounts.isEmpty {
                    ContentUnavailableView("No Accounts", systemImage: "shippingbox", description: Text("Add an S3, S3-compatible or OSS account."))
                }
            }
            VStack(spacing: 8) {
                Button {
                    newAccount()
                } label: {
                    Label("New Account", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button {
                    showingImport = true
                } label: {
                    Label("Import from CLI Config…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }
            .padding(12)
        }
        .placedBelowWindowToolbar()
    }

    private func filtered(_ accounts: [StorageAccount]) -> [StorageAccount] {
        guard !search.isEmpty else { return accounts }
        return accounts.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search) }
    }

    private func rows(_ accounts: [StorageAccount]) -> some View {
        ForEach(accounts) { account in
            AccountRow(account: account)
                .tag(account.id)
                .contextMenu {
                    Button("Connect") { session.connect(account: account, store: store) }
                    Divider()
                    Button(account.isFavorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(account) }
                    Button("Duplicate") { if let copy = store.duplicate(account) { selection = copy.id } }
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = account }
                }
                .onTapGesture(count: 2) { session.connect(account: account, store: store) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let draft {
            AccountEditorView(draft: draft, store: store, session: session) { saved in selection = saved.id }
                .id(draft.accountID ?? draft.account.id)
        } else {
            WelcomeView(onNew: newAccount, onImport: { showingImport = true })
        }
    }

    private func newAccount() {
        selection = nil
        draft = AccountDraft(account: nil, store: store, kind: .amazonS3)
    }
}

private struct AccountRow: View {
    let account: StorageAccount

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.color(for: account.color).gradient)
                    .frame(width: 26, height: 26)
                Image(systemName: account.kind.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName).lineLimit(1)
                Text(account.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if account.isReadOnly { Image(systemName: "lock.fill").foregroundStyle(.orange).imageScale(.small).help("Read-only") }
            if account.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small) }
        }
        .padding(.vertical, 2)
    }
}

private struct WelcomeView: View {
    let onNew: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            AppLogo(size: 92)
            VStack(spacing: 6) {
                Text("Welcome to CcinnBucket").font(.largeTitle.weight(.semibold))
                Text("A native object storage client for Amazon S3, S3-compatible services and Alibaba Cloud OSS.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("New Account…", action: onNew)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Import from CLI Config…", action: onImport)
                    .controlSize(.large)
            }
            HStack(spacing: 14) {
                FeaturePill(icon: "list.bullet.rectangle", text: "Millions of objects")
                FeaturePill(icon: "square.stack.3d.up", text: "Multipart & resume")
                FeaturePill(icon: "clock.arrow.circlepath", text: "Versions")
                FeaturePill(icon: "link", text: "Presigned links")
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// Edits one account: provider, endpoint, region, credentials, OSS options and safety settings.
struct AccountEditorView: View {
    @Bindable var draft: AccountDraft
    let store: AccountStore
    let session: WindowSession
    let onSaved: (StorageAccount) -> Void

    @State private var saveError: String?
    @State private var showSecret = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    ProviderPicker(selection: Binding(get: { draft.account.kind }, set: { draft.apply(kind: $0) }))
                    Form {
                        connectionSection
                        if draft.account.kind.provider == .oss { ossSection }
                        credentialsSection
                        optionsSection
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)

                    testResult
                    ForEach(draft.validationErrors, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    }
                    if let saveError { ErrorBanner(message: saveError) { self.saveError = nil } }
                    if let error = session.connectError { ErrorBanner(message: error) { session.connectError = nil } }
                }
                .padding(28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            Divider()
            actionBar
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.color(for: draft.account.color).gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: draft.account.kind.symbolName).foregroundStyle(.white).font(.system(size: 17, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Account name", text: $draft.account.name, prompt: Text(draft.account.displayName))
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(AccountColor.allCases.filter { $0 != .none }) { color in
                        Button {
                            draft.account.color = color
                        } label: {
                            Circle()
                                .fill(Theme.color(for: color))
                                .frame(width: 13, height: 13)
                                .overlay(Circle().strokeBorder(.primary.opacity(draft.account.color == color ? 0.8 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help(color.rawValue.capitalized)
                    }
                }
            }
            Spacer()
            Toggle(isOn: $draft.account.isFavorite) { Image(systemName: draft.account.isFavorite ? "star.fill" : "star") }
                .toggleStyle(.button)
                .help("Favorite")
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        let kind = draft.account.kind
        Section("Connection") {
            if kind.provider == .oss && draft.account.usesCustomDomain {
                TextField("Custom domain", text: $draft.account.endpoint, prompt: Text("https://static.example.com"))
            } else {
                TextField(kind.requiresEndpoint ? "Endpoint" : "Endpoint (optional)", text: $draft.account.endpoint,
                          prompt: Text(kind.endpointPlaceholder))
            }
            HStack {
                TextField("Region", text: $draft.account.region, prompt: Text(kind.defaultRegion))
                Menu {
                    ForEach(kind.suggestedRegions, id: \.self) { region in
                        Button(region) { draft.account.region = region }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if kind.provider == .s3 {
                Toggle("Path-style addressing (endpoint/bucket/key)", isOn: Binding(get: { draft.account.addressing == .path },
                                                                                    set: { draft.account.addressing = $0 ? .path : .virtualHosted }))
            }
            LabeledContent("Requests go to") {
                Text(draft.account.effectiveEndpointDescription).font(Theme.monospacedSmall).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var ossSection: some View {
        Section("Alibaba Cloud OSS") {
            Picker("Endpoint type", selection: $draft.account.ossEndpointKind) {
                Text("Public").tag(OSSEndpointKind.public)
                Text("Internal (VPC / ECS)").tag(OSSEndpointKind.internal)
                Text("Transfer acceleration").tag(OSSEndpointKind.accelerate)
            }
            .disabled(draft.account.usesCustomDomain)
            Toggle("Use a custom domain (CNAME)", isOn: $draft.account.usesCustomDomain)
            if draft.account.usesCustomDomain {
                TextField("Bucket bound to the domain", text: $draft.account.customDomainBucket, prompt: Text("my-bucket"))
            }
            Picker("Signature", selection: $draft.account.ossSignatureVersion) {
                Text("V4 (OSS4-HMAC-SHA256)").tag(OSSSignatureVersion.v4)
                Text("V1 (HMAC-SHA1, legacy)").tag(OSSSignatureVersion.v1)
            }
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        Section {
            TextField("Access key ID", text: $draft.account.accessKeyID)
                .font(Theme.monospacedSmall)
            HStack {
                Group {
                    if showSecret {
                        TextField("Secret access key", text: $draft.secretAccessKey)
                    } else {
                        SecureField("Secret access key", text: $draft.secretAccessKey)
                    }
                }
                .font(Theme.monospacedSmall)
                Button { showSecret.toggle() } label: { Image(systemName: showSecret ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
            }
            SecureField("Session token (STS, optional)", text: $draft.sessionToken)
                .font(Theme.monospacedSmall)
        } header: {
            Text("Credentials")
        } footer: {
            Text("The secret key and session token are stored only in your macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section("Options") {
            TextField("Default bucket (optional)", text: $draft.account.defaultBucket, prompt: Text("Opened on connect; used when listing buckets is not allowed"))
            Toggle("Read-only (refuse uploads, deletes and every other change)", isOn: $draft.account.isReadOnly)
            Picker("List API", selection: $draft.account.listAPIVersion) {
                Text("Automatic (V2, fall back to V1)").tag(ListAPIVersion.automatic)
                Text("ListObjectsV2").tag(ListAPIVersion.v2)
                Text("ListObjects (V1, older servers)").tag(ListAPIVersion.v1)
            }
            Picker("Multipart part size", selection: $draft.account.partSizeMiB) {
                ForEach([5, 8, 16, 32, 64, 128, 256], id: \.self) { Text("\($0) MiB").tag($0) }
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch draft.testState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Listing buckets…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { draft.cancelTest() }.buttonStyle(.borderless)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        case let .succeeded(message):
            Label {
                Text(message).textSelection(.enabled)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        case let .failed(message):
            ErrorBanner(message: message) { draft.testState = .idle }
        }
    }

    private var actionBar: some View {
        HStack {
            Button { draft.test() } label: { Label("Test", systemImage: "bolt.horizontal.circle") }
                .disabled(!draft.isValid)
            Spacer()
            Button("Save") { _ = save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!draft.isValid)
            Button {
                if let account = save() { session.connect(account: account, store: store) }
            } label: {
                Text(draft.accountID == nil ? "Save & Connect" : "Connect").frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func save() -> StorageAccount? {
        do {
            let saved = try store.save(draft.normalizedAccount(), secretAccessKey: draft.credentials.secretAccessKey,
                                       sessionToken: draft.credentials.sessionToken)
            saveError = nil
            onSaved(saved)
            return saved
        } catch {
            saveError = describe(error)
            return nil
        }
    }
}

/// Grid of provider presets.
private struct ProviderPicker: View {
    @Binding var selection: AccountKind

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(AccountKind.allCases) { kind in
                Button {
                    selection = kind
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(selection == kind ? Color.white : Theme.accent)
                        Text(kind.displayName).lineLimit(1).font(.callout)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .foregroundStyle(selection == kind ? Color.white : Color.primary)
                    .background(selection == kind ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(.quaternary.opacity(0.5)),
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lists credentials found in CLI configuration files and imports the selected ones.
struct ImportCredentialsSheet: View {
    let store: AccountStore
    let onImported: ([StorageAccount]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var found: [ImportedCredential] = []
    @State private var chosen = Set<String>()
    @State private var scanned = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import Credentials", systemImage: "square.and.arrow.down").font(.headline)
            Text("Read-only scan of ~/.aws/credentials (+ config), ~/.alibabacloud/credentials, ~/.ossutilconfig and ~/.aliyun/config.json. These files are never modified; imported secrets go to the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !scanned {
                ProgressView().controlSize(.small)
            } else if found.isEmpty {
                NoticeBanner(message: "No access-key profiles were found.", systemImage: "doc.questionmark")
            } else {
                List(found) { credential in
                    Toggle(isOn: Binding(get: { chosen.contains(credential.id) }, set: { on in
                        if on { chosen.insert(credential.id) } else { chosen.remove(credential.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(credential.profileName).font(.callout.weight(.medium))
                                Badge(text: credential.provider == .oss ? "OSS" : "S3", color: credential.provider == .oss ? .orange : Theme.accent)
                                if credential.sessionToken != nil { Badge(text: "STS", color: .purple) }
                            }
                            Text([credential.source, credential.region, credential.endpoint].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 240)
            }
            if let error { ErrorBanner(message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(chosen.count)") { importChosen() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            let results = await Task.detached { CredentialImport.scan() }.value
            found = results
            scanned = true
        }
    }

    private func importChosen() {
        var imported: [StorageAccount] = []
        for credential in found where chosen.contains(credential.id) {
            do {
                imported.append(try store.save(credential.makeAccount(), secretAccessKey: credential.secretAccessKey, sessionToken: credential.sessionToken))
            } catch {
                self.error = describe(error)
                return
            }
        }
        onImported(imported)
        dismiss()
    }
}
