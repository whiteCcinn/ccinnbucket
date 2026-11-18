import Decompression
import Foundation
import StorageKit
import UniformTypeIdentifiers

/// Formatting for sizes, rates, durations and counts.
public enum SizeFormat {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "—" }
        let clamped = min(bytesPerSecond, Double(Int64.max / 2))
        return bytes(Int64(clamped)) + "/s"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(min(seconds, 99 * 86_400).rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        if total < 86_400 { return "\(total / 3_600)h \((total % 3_600) / 60)m" }
        return "\(total / 86_400)d \((total % 86_400) / 3_600)h"
    }

    public static func count(_ value: Int) -> String { value.formatted() }
}

/// How (and whether) to preview an object, decided before downloading anything.
public struct PreviewPlan: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case text
        case json
        case image
        case pdf
        case quickLook
        case empty
        case tooLarge
        /// gzip or Zstandard: streamed and decompressed from the start, any size (`compression` says which).
        case compressed
    }

    public static let textLimit: Int64 = 1 << 20
    public static let jsonLimit: Int64 = 5 << 20
    public static let imageLimit: Int64 = 50 << 20
    public static let documentLimit: Int64 = 100 << 20

    public var kind: Kind
    /// Bytes to fetch (nil = whole object).
    public var range: ByteRange?
    public var isTruncated: Bool
    /// The compression of a `.compressed` object.
    public var compression: CompressionFormat?
    /// The (decompressed) content is JSON: shown indented.
    public var isJSON = false

    init(kind: Kind, range: ByteRange?, isTruncated: Bool, compression: CompressionFormat? = nil, isJSON: Bool = false) {
        self.kind = kind
        self.range = range
        self.isTruncated = isTruncated
        self.compression = compression
        self.isJSON = isJSON
    }

    static let textExtensions: Set<String> = [
        "txt", "log", "md", "markdown", "csv", "tsv", "yaml", "yml", "xml", "html", "htm", "css", "js", "mjs", "ts", "tsx", "jsx",
        "swift", "go", "rs", "py", "rb", "java", "kt", "c", "h", "cpp", "hpp", "m", "sh", "zsh", "bash", "toml", "ini", "conf",
        "cfg", "env", "sql", "properties", "gradle", "dockerfile", "makefile", "ndjson", "jsonl", "srt", "vtt", "tex", "rst",
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "svg", "avif"]

    public static func make(key: String, contentType: String?, size: Int64) -> PreviewPlan {
        guard !key.hasSuffix("/"), size > 0 else { return PreviewPlan(kind: .empty, range: nil, isTruncated: false) }
        let type = contentType?.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let ext = ObjectPath.fileExtension(of: key) ?? ""
        let isJSON = type == "application/json" || type.hasSuffix("+json") || ext == "json"
        let isText = type.hasPrefix("text/") || textExtensions.contains(ext) || type == "application/xml" || type == "application/javascript"
            || type == "application/x-ndjson" || type == "application/yaml"
        let isImage = type.hasPrefix("image/") || imageExtensions.contains(ext)
        let isPDF = type == "application/pdf" || ext == "pdf"

        if !isImage, !isPDF, let compression = CompressionFormat.fromExtension(ext) {
            // `bids.json.gz` → JSON inside gzip; `app.log.zst` → text inside Zstandard.
            let innerExtension = ObjectPath.fileExtension(of: String(key.dropLast(ext.count + 1))) ?? ""
            return PreviewPlan(kind: .compressed, range: nil, isTruncated: false, compression: compression,
                               isJSON: innerExtension == "json")
        }
        if isJSON, size <= jsonLimit { return PreviewPlan(kind: .json, range: nil, isTruncated: false, isJSON: true) }
        if isJSON || isText {
            let truncated = size > textLimit
            return PreviewPlan(kind: .text, range: truncated ? ByteRange(first: 0, last: textLimit - 1) : nil, isTruncated: truncated,
                               isJSON: isJSON)
        }
        if isImage { return PreviewPlan(kind: size <= imageLimit ? .image : .tooLarge, range: nil, isTruncated: false) }
        if isPDF { return PreviewPlan(kind: size <= documentLimit ? .pdf : .tooLarge, range: nil, isTruncated: false) }
        return PreviewPlan(kind: size <= documentLimit ? .quickLook : .tooLarge, range: nil, isTruncated: false)
    }
}

public enum ContentTypes {
    /// MIME type from the key's extension (falls back to `application/octet-stream`).
    public static func guess(forKey key: String) -> String {
        guard let ext = ObjectPath.fileExtension(of: key) else { return "application/octet-stream" }
        switch ext {
        case "json": return "application/json"
        case "ndjson", "jsonl": return "application/x-ndjson"
        case "md", "markdown": return "text/markdown; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "txt", "log": return "text/plain; charset=utf-8"
        case "csv": return "text/csv; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        default: break
        }
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return type.conforms(to: .text) && !mime.contains("charset") ? mime + "; charset=utf-8" : mime
        }
        return "application/octet-stream"
    }
}
