import CcinnBucketKit
import StorageKit
import SwiftUI

/// Bucket list with filter, create/delete and settings.
struct BucketSidebar: View {
    @Bindable var workspace: WorkspaceModel
    @State private var deleting: BucketInfo?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter buckets", text: $workspace.bucketFilter).textFieldStyle(.plain)
                if !workspace.bucketFilter.isEmpty {
                    Button { workspace.bucketFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            List(selection: Binding(get: { workspace.selectedBucket }, set: { name in if let name { workspace.open(bucket: name) } })) {
                Section {
                    if let error = workspace.bucketsError {
                        ErrorBanner(message: error).listRowSeparator(.hidden)
                    }
                    ForEach(workspace.visibleBuckets) { bucket in
                        BucketRow(bucket: bucket, region: workspace.region(of: bucket.name))
                            .tag(bucket.name)
                            .contextMenu { menu(for: bucket) }
                    }
                } header: {
                    HStack {
                        Text("Buckets")
                        Spacer()
                        Text(workspace.buckets.count.formatted()).monospacedDigit()
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if workspace.buckets.isEmpty, !workspace.isLoadingBuckets, workspace.bucketsError == nil {
                    ContentUnavailableView("No Buckets", systemImage: "shippingbox", description: Text("Create a bucket to get started."))
                }
            }
            HStack(spacing: 8) {
                Button { workspace.isCreatingBucket = true } label: { Label("New Bucket", systemImage: "plus") }
                    .disabled(workspace.isReadOnly)
                Spacer()
                if workspace.isLoadingBuckets { ProgressView().controlSize(.small) }
                Button { workspace.refreshBuckets() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload buckets")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .placedBelowWindowToolbar()
        .sheet(item: $deleting) { bucket in DeleteBucketSheet(workspace: workspace, bucket: bucket) }
    }

    @ViewBuilder
    private func menu(for bucket: BucketInfo) -> some View {
        Button("Open") { workspace.open(bucket: bucket.name) }
        Button("Bucket Settings…") { workspace.settingsBucket = bucket.name }
        Divider()
        Button("Copy Name") { Pasteboard.copy(bucket.name) }
        Button(workspace.capabilities.provider == .oss ? "Copy oss:// URI" : "Copy s3:// URI") {
            Pasteboard.copy("\(workspace.capabilities.provider == .oss ? "oss" : "s3")://\(bucket.name)/")
        }
        Divider()
        Button("Delete Bucket…", role: .destructive) { deleting = bucket }
            .disabled(workspace.isReadOnly)
    }
}

private struct BucketRow: View {
    let bucket: BucketInfo
    let region: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Theme.accent.gradient)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(bucket.name).lineLimit(1).truncationMode(.middle)
                if let created = bucket.creationDate {
                    Text("Created \(created.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let region, !region.isEmpty { Badge(text: region, color: .secondary) }
        }
        .padding(.vertical, 2)
    }
}

/// Bucket creation with live name validation.
struct CreateBucketSheet: View {
    let workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var region = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("New Bucket", systemImage: "shippingbox").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("my-bucket"))
                if workspace.account.kind == .amazonS3 || workspace.account.kind == .alibabaOSS {
                    Picker("Region", selection: $region) {
                        ForEach(workspace.account.kind.suggestedRegions, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    LabeledContent("Region", value: workspace.account.region)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    working = true
                    Task {
                        let created = await workspace.createBucket(name: name, region: region.isEmpty ? nil : region)
                        working = false
                        if created { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || !problems.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { region = workspace.account.region }
    }

    private var problems: [String] {
        name.isEmpty ? [] : BucketNaming.violations(name, provider: workspace.capabilities.provider)
    }
}

/// Bucket deletion requires typing the bucket name.
struct DeleteBucketSheet: View {
    let workspace: WorkspaceModel
    let bucket: BucketInfo
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Delete bucket “\(bucket.name)”?", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Only empty buckets can be deleted. This cannot be undone. Type the bucket name to confirm.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(bucket.name, text: $typed).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete Bucket", role: .destructive) {
                    let target = bucket
                    dismiss()
                    Task { await workspace.deleteBucket(target) }
                }
                .disabled(typed != bucket.name)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
