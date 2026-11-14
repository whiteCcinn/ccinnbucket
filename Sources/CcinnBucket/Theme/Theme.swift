import AppKit
import CcinnBucketKit
import StorageKit
import SwiftUI

/// Visual language: one accent ("lagoon sky"), consistent metrics, and a distinct icon + colour for
/// folders, file types, storage classes and transfer directions.
enum Theme {
    static let accent = Color(nsColor: .appAccent)

    enum Metrics {
        static let cornerRadius: CGFloat = 10
        static let smallCornerRadius: CGFloat = 6
        static let cardPadding: CGFloat = 14
    }

    static let monospaced = Font.system(size: 12, design: .monospaced)
    static let monospacedSmall = Font.system(size: 11, design: .monospaced)

    static func color(for accountColor: AccountColor) -> Color {
        switch accountColor {
        case .none: .secondary
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }

    /// SF Symbol for a key (by extension) or folder.
    static func symbol(forKey key: String, isFolder: Bool) -> String {
        if isFolder { return "folder.fill" }
        switch ObjectPath.fileExtension(of: key) ?? "" {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg", "raw", "avif", "ico": return "photo"
        case "mp4", "mov", "m4v", "mkv", "webm", "avi": return "film"
        case "mp3", "m4a", "wav", "flac", "aac", "ogg": return "waveform"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar", "zst": return "doc.zipper"
        case "json", "ndjson", "jsonl", "yaml", "yml", "toml", "xml": return "curlybraces"
        case "csv", "tsv", "xlsx", "xls", "parquet": return "tablecells"
        case "log": return "list.bullet.rectangle"
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "html", "htm", "css", "js", "ts", "swift", "go", "rs", "py", "java", "c", "cpp", "h", "sh", "sql": return "chevron.left.forwardslash.chevron.right"
        case "iso", "dmg", "img": return "opticaldisc"
        default: return "doc"
        }
    }

    static func nsColor(forKey key: String, isFolder: Bool) -> NSColor {
        if isFolder { return .folderTint }
        switch symbol(forKey: key, isFolder: false) {
        case "photo": return .systemPink
        case "film": return .systemPurple
        case "waveform": return .systemOrange
        case "doc.richtext": return .systemRed
        case "doc.zipper": return .systemBrown
        case "curlybraces": return .systemTeal
        case "tablecells": return .systemGreen
        case "chevron.left.forwardslash.chevron.right": return .systemIndigo
        default: return .secondaryLabelColor
        }
    }

    static func color(forStorageClass storageClass: String?) -> Color {
        switch (storageClass ?? "").uppercased() {
        case "", "STANDARD": .secondary
        case "STANDARD_IA", "ONEZONE_IA", "IA", "INTELLIGENT_TIERING": .blue
        case "GLACIER_IR", "ARCHIVE": .indigo
        case "GLACIER", "DEEP_ARCHIVE", "COLDARCHIVE", "DEEPCOLDARCHIVE": .purple
        case "REDUCED_REDUNDANCY": .orange
        default: .teal
        }
    }

    static func symbol(for direction: TransferDirection) -> String {
        switch direction {
        case .upload: "arrow.up.circle.fill"
        case .download: "arrow.down.circle.fill"
        case .copy: "doc.on.doc.fill"
        case .move: "arrow.right.circle.fill"
        case .delete: "trash.circle.fill"
        }
    }

    static func color(for direction: TransferDirection) -> Color {
        switch direction {
        case .upload: Color(nsColor: .appAccent)
        case .download: .green
        case .copy, .move: .indigo
        case .delete: .red
        }
    }
}

extension NSColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// "Lagoon sky": distinct from CcinnMongo's green and CcinnStarRocks' indigo.
    static let appAccent = adaptive(light: .hex(0x0284C7), dark: .hex(0x38BDF8))
    static let folderTint = adaptive(light: .hex(0x0EA5E9), dark: .hex(0x7DD3FC))
}

enum Format {
    static let dateTime: Date.FormatStyle = .dateTime.year().month(.abbreviated).day().hour().minute()

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(dateTime)
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return SizeFormat.bytes(value)
    }

    static func exactBytes(_ value: Int64) -> String { "\(value.formatted()) bytes" }
}

/// Small rounded label used for regions, providers, states and storage classes.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Inline error presentation with a copy affordance.
struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Pasteboard.copy(message)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy error")
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(Color.red.opacity(0.25)))
    }
}

/// Informational (non-error) notice.
struct NoticeBanner: View {
    let message: String
    var systemImage = "info.circle"
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(message).font(.callout).textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
    }
}

/// Card container used across the app.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(Theme.accent) }
                    Text(title)
                }
                .font(.headline)
            }
            content
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// Two-column key/value list.
struct KeyValueList: View {
    let items: [(String, String)]
    var monospacedValues = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                GridRow {
                    Text(item.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(item.1)
                        .font(monospacedValues ? Theme.monospacedSmall : .callout)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The app mark, drawn in SwiftUI so it matches the generated app icon.
struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.22, green: 0.74, blue: 0.97), Color(red: 0.01, green: 0.40, blue: 0.70),
                                              Color(red: 0.05, green: 0.20, blue: 0.42)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            BucketGlyph()
                .fill(.white.opacity(0.95))
                .frame(width: size * 0.56, height: size * 0.56)
                .offset(y: size * 0.03)
                .shadow(color: .black.opacity(0.25), radius: size * 0.04, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: size * 0.08, y: size * 0.04)
    }
}

/// Bucket outline with stacked "object" bands, shared by the logo and the icon script.
struct BucketGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
        // Rim (ellipse ring).
        let rim = CGRect(x: x + w * 0.04, y: y + h * 0.08, width: w * 0.92, height: h * 0.22)
        path.addEllipse(in: rim)
        path.addEllipse(in: rim.insetBy(dx: w * 0.07, dy: h * 0.035))
        // Body: three bands narrowing downwards (objects stacked in the bucket).
        let bands: [(CGFloat, CGFloat, CGFloat)] = [(0.30, 0.50, 0.10), (0.53, 0.72, 0.15), (0.75, 0.94, 0.20)]
        for (top, bottom, inset) in bands {
            let topInset = inset - 0.02
            var band = Path()
            band.move(to: CGPoint(x: x + w * topInset, y: y + h * top))
            band.addLine(to: CGPoint(x: x + w * (1 - topInset), y: y + h * top))
            band.addLine(to: CGPoint(x: x + w * (1 - inset - 0.02), y: y + h * bottom))
            band.addQuadCurve(to: CGPoint(x: x + w * (inset + 0.02), y: y + h * bottom), control: CGPoint(x: x + w * 0.5, y: y + h * (bottom + 0.05)))
            band.closeSubpath()
            path.addPath(band)
        }
        return path
    }
}
