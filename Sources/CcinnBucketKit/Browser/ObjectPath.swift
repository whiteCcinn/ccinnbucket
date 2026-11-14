import Foundation

/// A place in the browser: a bucket and a folder prefix (empty = bucket root, otherwise ending in `/`).
public struct BrowserLocation: Hashable, Sendable, Codable {
    public var bucket: String
    public var prefix: String

    public init(bucket: String, prefix: String = "") {
        self.bucket = bucket
        self.prefix = prefix
    }
}

/// Pure helpers for "folder" semantics on top of flat keys with `/` delimiters.
public enum ObjectPath {
    public struct Crumb: Hashable, Sendable {
        public var title: String
        public var prefix: String
    }

    /// `photos/2024/` → [photos → `photos/`, 2024 → `photos/2024/`]. Empty segments (from `//`) are kept.
    public static func breadcrumbs(prefix: String) -> [Crumb] {
        guard !prefix.isEmpty else { return [] }
        var crumbs: [Crumb] = []
        var accumulated = ""
        let body = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        for segment in body.split(separator: "/", omittingEmptySubsequences: false) {
            accumulated += segment + "/"
            crumbs.append(Crumb(title: String(segment), prefix: accumulated))
        }
        return crumbs
    }

    /// The enclosing folder prefix, or nil at the bucket root.
    public static func parent(of prefix: String) -> String? {
        guard !prefix.isEmpty else { return nil }
        let body = prefix.hasSuffix("/") ? prefix.dropLast() : Substring(prefix)
        guard let slash = body.lastIndex(of: "/") else { return "" }
        return String(body[...slash])
    }

    /// Name of `key` relative to the folder `prefix`, without the trailing `/` of folders.
    public static func displayName(of key: String, in prefix: String) -> String {
        var name = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        if name.hasSuffix("/") { name.removeLast() }
        return name.isEmpty ? "(empty name)" : name
    }

    /// Last path component of a key or prefix.
    public static func lastComponent(of key: String) -> String {
        let body = key.hasSuffix("/") ? String(key.dropLast()) : key
        return body.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? body
    }

    /// Lower-cased extension of the last component (nil for none or dot-files).
    public static func fileExtension(of key: String) -> String? {
        let name = lastComponent(of: key)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// Server-side listing prefix for a folder plus the filter text typed by the user.
    public static func listingPrefix(folder: String, filter: String) -> String {
        folder + filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Back/forward navigation like Finder (bounded).
public struct NavigationHistory: Sendable, Hashable {
    public static let limit = 100

    public private(set) var current: BrowserLocation
    private var back: [BrowserLocation] = []
    private var forward: [BrowserLocation] = []

    public init(start: BrowserLocation) {
        current = start
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    public mutating func visit(_ location: BrowserLocation) {
        guard location != current else { return }
        back.append(current)
        if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        forward.removeAll()
        current = location
    }

    @discardableResult
    public mutating func goBack() -> BrowserLocation? {
        guard let previous = back.popLast() else { return nil }
        forward.append(current)
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward() -> BrowserLocation? {
        guard let next = forward.popLast() else { return nil }
        back.append(current)
        current = next
        return next
    }
}
