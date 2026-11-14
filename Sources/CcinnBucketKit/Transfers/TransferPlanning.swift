import CryptoKit
import Foundation
import StorageKit

/// One local file to upload and its destination key.
public struct UploadEntry: Hashable, Sendable {
    public var file: URL
    public var key: String
    public var size: Int64
}

/// Expands dropped files and folders into upload entries.
public enum UploadPlanner {
    public static let maximumEntries = 1_000_000

    public struct PlanError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// - Folders keep their name and structure (`site/` dropped on `www/` → `www/site/...`).
    /// - `.DS_Store` is always skipped; other hidden files unless `includeHidden`.
    /// - Symbolic links are never followed (they could point outside the dropped tree).
    /// - Names are normalised to NFC so keys match what other tools produce.
    public static func plan(_ urls: [URL], destinationPrefix: String, includeHidden: Bool = false) throws -> [UploadEntry] {
        var entries: [UploadEntry] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey]
        func skip(_ name: String) -> Bool { name == ".DS_Store" || (!includeHidden && name.hasPrefix(".")) }

        for url in urls {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
            if values.isSymbolicLink == true || skip(name) { continue }
            if values.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                                      errorHandler: { _, _ in true }) else { continue }
                let base = url.standardizedFileURL.pathComponents
                while let child = enumerator.nextObject() as? URL {
                    let childValues = try? child.resourceValues(forKeys: Set(keys))
                    let childName = child.lastPathComponent
                    if childValues?.isSymbolicLink == true || skip(childName) {
                        if childValues?.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    guard childValues?.isRegularFile == true else { continue }
                    let relative = child.standardizedFileURL.pathComponents.dropFirst(base.count)
                        .map { $0.precomposedStringWithCanonicalMapping }
                    let key = destinationPrefix + name + "/" + relative.joined(separator: "/")
                    entries.append(UploadEntry(file: child, key: key, size: Int64(childValues?.fileSize ?? 0)))
                    guard entries.count <= maximumEntries else {
                        throw PlanError(message: "More than \(maximumEntries.formatted()) files were dropped; upload a smaller selection.")
                    }
                }
            } else if values.isRegularFile == true {
                entries.append(UploadEntry(file: url, key: destinationPrefix + name, size: Int64(values.fileSize ?? 0)))
            }
        }
        return entries
    }
}

/// Maps object keys to local paths for downloads, guaranteeing the result stays inside `root`.
public enum LocalPathMapper {
    /// - Returns: nil for keys that do not name a file (folder markers, empty keys).
    public static func localURL(forKey key: String, relativeTo prefix: String, root: URL) -> URL? {
        guard !key.isEmpty, !key.hasSuffix("/") else { return nil }
        let relative = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map { sanitize(String($0)) }
        guard !components.isEmpty else { return nil }
        var url = root.standardizedFileURL
        for (index, component) in components.enumerated() {
            url.appendPathComponent(component, isDirectory: index < components.count - 1)
        }
        let rootPath = root.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
        return url
    }

    /// Neutralises `.`/`..`, NUL and `:` and keeps components within 255 UTF-8 bytes.
    static func sanitize(_ component: String) -> String {
        var name = component.replacingOccurrences(of: "\u{0}", with: "_").replacingOccurrences(of: ":", with: "_")
        if name == "." || name == ".." { name = "_" + name }
        // File systems limit names to 255 bytes; measure the decomposed form, which is the longest.
        func length(_ text: String) -> Int { text.decomposedStringWithCanonicalMapping.utf8.count }
        guard length(name) > 255 else { return name }
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let ext = (name as NSString).pathExtension
        let suffix = "~" + digest + (ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext)
        var stem = ""
        for character in name {
            if length(stem + String(character)) + suffix.utf8.count > 255 { break }
            stem.append(character)
        }
        return stem + suffix
    }

    /// A non-conflicting variant of `url` ("name 2.ext", "name 3.ext", …) for "keep both".
    public static func uniqueURL(for url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for index in 2..<10_000 {
            let candidate = directory.appendingPathComponent(ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : ".\(ext)"))
    }
}

/// Exponentially weighted throughput (bytes/s) with a time-based smoothing factor.
public struct ThroughputMeter: Sendable, Hashable {
    public let halfLife: TimeInterval
    public private(set) var bytesPerSecond: Double = 0
    private var lastTime: Date?
    private var lastBytes: Int64 = 0

    public init(halfLife: TimeInterval = 2) {
        self.halfLife = max(0.1, halfLife)
    }

    public mutating func record(totalBytes: Int64, at time: Date) {
        guard let lastTime else {
            self.lastTime = time
            lastBytes = totalBytes
            return
        }
        let elapsed = time.timeIntervalSince(lastTime)
        guard elapsed >= 0.05 else { return }
        let instantaneous = max(0, Double(totalBytes - lastBytes)) / elapsed
        let alpha = 1 - pow(0.5, elapsed / halfLife)
        bytesPerSecond = max(0, bytesPerSecond + alpha * (instantaneous - bytesPerSecond))
        if !bytesPerSecond.isFinite { bytesPerSecond = 0 }
        self.lastTime = time
        lastBytes = totalBytes
    }

    public mutating func reset() {
        bytesPerSecond = 0
        lastTime = nil
        lastBytes = 0
    }

    public func remainingTime(forRemaining bytes: Int64) -> TimeInterval? {
        guard bytesPerSecond > 1, bytes > 0 else { return nil }
        return Double(bytes) / bytesPerSecond
    }
}

/// Key rewriting for rename/move and name validation.
public enum KeyRewrite {
    /// Renames the last component of a key or folder prefix.
    public static func renamed(key: String, newName: String) -> String {
        let isFolder = key.hasSuffix("/")
        let parent = ObjectPath.parent(of: isFolder ? key : key + "/") ?? ""
        return parent + newName + (isFolder ? "/" : "")
    }

    /// `key` under folder `from` moved to folder `to`.
    public static func moved(key: String, from: String, to: String) -> String {
        guard key.hasPrefix(from) else { return to + ObjectPath.lastComponent(of: key) }
        return to + key.dropFirst(from.count)
    }

    public static func isInside(_ key: String, folder: String) -> Bool { key.hasPrefix(folder) && key != folder }

    /// A user-facing problem with a new name, or nil when it is acceptable.
    public static func validateName(_ name: String) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name.contains("/") { return "Names cannot contain “/”." }
        if name == "." || name == ".." { return "“\(name)” is not a valid name." }
        if name.utf8.count > 1_024 { return "The name is too long." }
        if !XMLWriter.isRepresentable(name) || name.unicodeScalars.contains(where: { $0.value < 0x20 }) { return "Names cannot contain control characters." }
        return nil
    }
}

public struct PresignExpiry: Hashable, Sendable, Identifiable {
    public var title: String
    public var seconds: Int
    public var id: Int { seconds }

    public static let presets = [
        PresignExpiry(title: "5 minutes", seconds: 300), PresignExpiry(title: "1 hour", seconds: 3_600),
        PresignExpiry(title: "12 hours", seconds: 43_200), PresignExpiry(title: "1 day", seconds: 86_400),
        PresignExpiry(title: "7 days", seconds: 604_800),
    ]

    public static func validate(seconds: Int, maximum: Int) -> String? {
        guard seconds >= 1 else { return "The link must be valid for at least one second." }
        guard seconds <= maximum else { return "Links can be valid for at most \(maximum / 86_400) days." }
        return nil
    }
}
