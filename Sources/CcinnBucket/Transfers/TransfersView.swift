import CcinnBucketKit
import StorageKit
import SwiftUI

/// Transfer queue panel (bottom drawer): every job with progress, speed and controls, plus aggregate throughput.
struct TransfersPanel: View {
    let model: TransfersModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Transfers", systemImage: "arrow.up.arrow.down.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.accent)
                if model.activeCount > 0 {
                    Badge(text: "\(model.activeCount) active", color: Theme.accent)
                    Text(SizeFormat.rate(model.snapshot.totalBytesPerSecond))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button("Clear Finished") { model.clearFinished() }
                    .disabled(!model.jobs.contains { $0.status == .completed || $0.status == .cancelled })
                Button(action: onClose) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Hide transfers")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            if model.jobs.isEmpty {
                ContentUnavailableView("No Transfers", systemImage: "arrow.up.arrow.down",
                                       description: Text("Uploads, downloads, copies and deletions appear here."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.jobs.reversed()) { job in
                        TransferRow(job: job, model: model)
                            .listRowSeparator(.visible)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct TransferRow: View {
    let job: TransferJob
    let model: TransfersModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: Theme.symbol(for: job.direction))
                .font(.system(size: 22))
                .foregroundStyle(Theme.color(for: job.direction).gradient)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(job.title).font(.callout.weight(.medium)).lineLimit(1)
                    statusBadge
                    Spacer(minLength: 0)
                }
                ProgressView(value: job.fractionCompleted)
                    .progressViewStyle(.linear)
                    .tint(tint)
                HStack(spacing: 6) {
                    Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(job.subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                if let failure = job.failures.first {
                    Text("\(failure.name): \(failure.message)\(job.failures.count > 1 ? " (+\(job.failures.count - 1) more)" : "")")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            controls
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch job.status {
        case .failed: .red
        case .paused: .orange
        case .cancelled: .secondary
        case .completed: .green
        default: Theme.color(for: job.direction)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch job.status {
        case .queued: Badge(text: "Queued")
        case .running: EmptyView()
        case .paused: Badge(text: "Paused", color: .orange, systemImage: "pause.fill")
        case .completed: Badge(text: "Done", color: .green, systemImage: "checkmark")
        case .failed: Badge(text: "Failed", color: .red, systemImage: "exclamationmark.triangle.fill")
        case .cancelled: Badge(text: "Cancelled")
        }
    }

    private var detail: String {
        let unit = job.direction == .delete
        let amount = unit ? "\(job.transferredBytes.formatted()) of \(job.totalBytes.formatted()) objects"
            : "\(SizeFormat.bytes(job.transferredBytes)) of \(SizeFormat.bytes(job.totalBytes))"
        var parts = [amount]
        if job.totalItems > 1 { parts.append("\(job.completedItems.formatted())/\(job.totalItems.formatted()) items") }
        if job.status == .running {
            if !unit, job.bytesPerSecond > 0 { parts.append(SizeFormat.rate(job.bytesPerSecond)) }
            if let remaining = job.remainingTime { parts.append("\(SizeFormat.duration(remaining)) left") }
            if let current = job.currentItem, job.totalItems > 1 { parts.append(current) }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            if job.canPause {
                Button { model.pause(job.id) } label: { Image(systemName: "pause.circle") }.help("Pause")
            }
            if job.canResume {
                Button { model.resume(job.id) } label: { Image(systemName: "play.circle") }.help("Resume")
            }
            if job.canRetry {
                Button { model.retry(job.id) } label: { Image(systemName: "arrow.clockwise.circle") }.help("Retry failed items")
            }
            if job.canCancel {
                Button { model.cancel(job.id) } label: { Image(systemName: "xmark.circle") }
                    .help(job.direction == .upload ? "Cancel (aborts the multipart upload)" : "Cancel")
            } else {
                Button { model.remove(job.id) } label: { Image(systemName: "minus.circle") }.help("Remove from list")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 17))
        .foregroundStyle(.secondary)
    }
}

/// Toolbar button showing transfer activity.
struct TransfersToolbarButton: View {
    let model: TransfersModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let fraction = model.overallFraction {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.03, fraction))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 8, weight: .bold))
                } else {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
            }
            .frame(width: 18, height: 18)
        }
        .help(model.activeCount > 0 ? "\(model.activeCount) transfers · \(SizeFormat.rate(model.snapshot.totalBytesPerSecond))" : "Transfers")
    }
}
