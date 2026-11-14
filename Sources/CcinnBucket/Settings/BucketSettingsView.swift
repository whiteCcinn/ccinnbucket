import CcinnBucketKit
import StorageKit
import SwiftUI

/// Bucket configuration viewer: versioning (toggle), lifecycle, CORS, policy, ACL, encryption, incomplete uploads.
struct BucketSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case versioning = "Versioning"
        case lifecycle = "Lifecycle"
        case cors = "CORS"
        case policy = "Policy"
        case acl = "Access"
        case encryption = "Encryption"
        case uploads = "Incomplete Uploads"

        var id: String { rawValue }

        var kind: BucketSettingKind? {
            switch self {
            case .versioning: .versioning
            case .lifecycle: .lifecycle
            case .cors: .cors
            case .policy: .policy
            case .acl: .acl
            case .encryption: .encryption
            case .uploads: nil
            }
        }

        var symbol: String {
            switch self {
            case .versioning: "clock.arrow.circlepath"
            case .lifecycle: "arrow.triangle.2.circlepath"
            case .cors: "globe"
            case .policy: "doc.badge.gearshape"
            case .acl: "person.2.badge.key"
            case .encryption: "lock.shield"
            case .uploads: "square.stack.3d.up.slash"
            }
        }
    }

    let workspace: WorkspaceModel
    let bucket: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .versioning
    @State private var documents: [BucketSettingKind: BucketSettingDocument] = [:]
    @State private var loading = Set<BucketSettingKind>()
    @State private var confirmVersioning: Bool?

    init(workspace: WorkspaceModel, bucket: String, initialTab: Tab = .versioning) {
        self.workspace = workspace
        self.bucket = bucket
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(Theme.accent.gradient)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bucket).font(.title3.weight(.semibold))
                    Text([workspace.region(of: bucket), workspace.account.kind.displayName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Divider()
            Group {
                if tab == .uploads {
                    IncompleteUploadsView(workspace: workspace, bucket: bucket)
                } else if let kind = tab.kind {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if kind == .versioning { versioningControls }
                            documentView(kind)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .task(id: kind) { await load(kind) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 600)
        .confirmationDialog(confirmVersioning == true ? "Enable versioning on “\(bucket)”?" : "Suspend versioning on “\(bucket)”?",
                            isPresented: Binding(get: { confirmVersioning != nil }, set: { if !$0 { confirmVersioning = nil } }),
                            titleVisibility: .visible) {
            Button(confirmVersioning == true ? "Enable" : "Suspend") {
                if let enabled = confirmVersioning { setVersioning(enabled) }
                confirmVersioning = nil
            }
        } message: {
            Text(confirmVersioning == true
                 ? "Every overwrite and delete will keep the previous version. Versioning cannot be fully turned off later, only suspended."
                 : "New writes will no longer create versions. Existing versions are kept.")
        }
    }

    @ViewBuilder
    private var versioningControls: some View {
        let state = documents[.versioning]
        let enabled = state?.items.first?.fields.first?.value == VersioningStatus.enabled.rawValue
        Card(title: "Versioning", systemImage: "clock.arrow.circlepath") {
            HStack {
                Text(enabled ? "Versioning is enabled. Previous versions and delete markers are kept."
                     : "Versioning is off or suspended. Overwrites and deletes are permanent.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(enabled ? "Suspend Versioning…" : "Enable Versioning…") { confirmVersioning = !enabled }
                    .disabled(workspace.isReadOnly || state == nil || state?.state == .failed || state?.state == .unsupported)
            }
        }
    }

    @ViewBuilder
    private func documentView(_ kind: BucketSettingKind) -> some View {
        if loading.contains(kind), documents[kind] == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
        } else if let document = documents[kind] {
            switch document.state {
            case .notConfigured where kind != .versioning:
                NoticeBanner(message: "No \(kind.title.lowercased()) configuration is set on this bucket.", systemImage: "circle.dashed")
            case .unsupported:
                NoticeBanner(message: document.message ?? "Not supported by this service.", systemImage: "nosign", color: .orange)
            case .failed:
                ErrorBanner(message: document.message ?? "Could not read the configuration.")
            default:
                ForEach(Array(document.items.enumerated()), id: \.offset) { _, item in
                    Card(title: item.title, systemImage: symbol(for: kind)) {
                        KeyValueList(items: item.fields.map { ($0.label, $0.value) })
                    }
                }
                if !document.raw.isEmpty {
                    DisclosureGroup("Raw document") {
                        Text(document.raw)
                            .font(Theme.monospacedSmall)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
                    }
                    .font(.callout)
                }
            }
            if kind != .versioning, document.state != .failed {
                Text("Read-only view. Edit this configuration with the provider's console or CLI.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func symbol(for kind: BucketSettingKind) -> String {
        Tab.allCases.first { $0.kind == kind }?.symbol ?? "gearshape"
    }

    private func load(_ kind: BucketSettingKind) async {
        guard documents[kind] == nil else { return }
        loading.insert(kind)
        do {
            documents[kind] = try await workspace.storage.bucketSetting(kind, bucket: bucket)
        } catch {
            documents[kind] = BucketSettingDocument(kind: kind, state: .failed, message: describe(error))
        }
        loading.remove(kind)
    }

    private func setVersioning(_ enabled: Bool) {
        Task {
            do {
                try await workspace.storage.setVersioning(bucket: bucket, enabled: enabled)
                documents[.versioning] = nil
                await load(.versioning)
                workspace.showToast(enabled ? "Versioning enabled on “\(bucket)”" : "Versioning suspended on “\(bucket)”")
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
        }
    }
}

/// Lists incomplete multipart uploads (paged) and aborts selected ones.
private struct IncompleteUploadsView: View {
    let workspace: WorkspaceModel
    let bucket: String
    @State private var uploads: [MultipartUploadInfo] = []
    @State private var selection = Set<String>()
    @State private var marker: (key: String?, upload: String?) = (nil, nil)
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?
    @State private var confirmAbort = false

    var body: some View {
        VStack(spacing: 0) {
            if let error { ErrorBanner(message: error).padding(12) }
            Table(uploads, selection: $selection) {
                TableColumn("Key") { upload in Text(upload.key).lineLimit(1).truncationMode(.middle).help(upload.key) }
                    .width(min: 200, ideal: 360)
                TableColumn("Upload ID") { upload in Text(upload.uploadID).font(Theme.monospacedSmall).lineLimit(1).truncationMode(.middle) }
                    .width(min: 120, ideal: 220)
                TableColumn("Started") { upload in Text(Format.date(upload.initiated)).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 160)
            }
            .overlay {
                if uploads.isEmpty, !loading, error == nil {
                    ContentUnavailableView("No Incomplete Uploads", systemImage: "checkmark.seal",
                                           description: Text("Interrupted multipart uploads keep their parts (and their storage cost) until aborted."))
                }
            }
            Divider()
            HStack {
                Text("\(uploads.count.formatted()) incomplete upload\(uploads.count == 1 ? "" : "s")\(hasMore ? " (more available)" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.mini) }
                if hasMore { Button("Load More") { Task { await load(reset: false) } }.buttonStyle(.link).font(.caption) }
                Spacer()
                Button("Refresh") { Task { await load(reset: true) } }
                Button("Abort Selected…", role: .destructive) { confirmAbort = true }
                    .disabled(selection.isEmpty || workspace.isReadOnly)
            }
            .padding(10)
        }
        .task { await load(reset: true) }
        .confirmationDialog("Abort \(selection.count) upload\(selection.count == 1 ? "" : "s")?", isPresented: $confirmAbort, titleVisibility: .visible) {
            Button("Abort Uploads", role: .destructive) { Task { await abortSelected() } }
        } message: {
            Text("Their uploaded parts are deleted. Transfers using them cannot be resumed.")
        }
    }

    private func load(reset: Bool) async {
        loading = true
        error = nil
        if reset {
            uploads = []
            marker = (nil, nil)
            selection = []
        }
        do {
            let page = try await workspace.storage.listMultipartUploads(bucket: bucket, prefix: "", keyMarker: marker.key, uploadIDMarker: marker.upload)
            uploads += page.uploads
            marker = (page.nextKeyMarker, page.nextUploadIDMarker)
            hasMore = page.isTruncated
        } catch {
            self.error = describe(error)
        }
        loading = false
    }

    private func abortSelected() async {
        let targets = uploads.filter { selection.contains($0.id) }
        var failures = 0
        for upload in targets {
            do {
                try await workspace.storage.abortMultipartUpload(bucket: bucket, key: upload.key, uploadID: upload.uploadID)
                uploads.removeAll { $0.id == upload.id }
            } catch {
                failures += 1
                self.error = describe(error)
            }
        }
        selection = []
        workspace.showToast(failures == 0 ? "Aborted \(targets.count) upload\(targets.count == 1 ? "" : "s")" : "\(failures) uploads could not be aborted",
                            isError: failures > 0)
    }
}
