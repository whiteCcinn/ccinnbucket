import Foundation

/// Limits applied to every XML document read from the network.
public struct XMLLimits: Sendable, Hashable {
    public var maxBytes: Int
    public var maxDepth: Int
    public var maxElements: Int
    public var maxTextBytes: Int

    public init(maxBytes: Int, maxDepth: Int, maxElements: Int, maxTextBytes: Int) {
        self.maxBytes = maxBytes
        self.maxDepth = maxDepth
        self.maxElements = maxElements
        self.maxTextBytes = maxTextBytes
    }

    /// Generous for storage APIs (a 1,000-key listing is ~0.5 MB) but bounded.
    public static let `default` = XMLLimits(maxBytes: 32 << 20, maxDepth: 64, maxElements: 1_000_000, maxTextBytes: 8 << 20)
}

/// A parsed XML element (namespace prefixes stripped from names).
public struct XElement: Sendable, Hashable {
    public var name: String
    public var attributes: [String: String]
    public var children: [XElement]
    public var text: String

    public init(name: String, attributes: [String: String] = [:], children: [XElement] = [], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    public func child(_ name: String) -> XElement? { children.first { $0.name == name } }

    public func children(_ name: String) -> [XElement] { children.filter { $0.name == name } }

    /// Text of the first child with this name (nil when absent).
    public func childText(_ name: String) -> String? { child(name)?.text }

    /// Follows a path of child names, e.g. `element.path("Filter", "Prefix")`.
    public func path(_ names: String...) -> XElement? {
        var current: XElement? = self
        for name in names { current = current?.child(name) }
        return current
    }
}

public enum XMLReader {
    /// Parses `data` into an element tree, enforcing `limits`. DTDs are rejected outright (no entity
    /// expansion, no external entities). Every failure is a `StorageError` with kind `.invalidResponse`.
    public static func parse(_ data: Data, limits: XMLLimits = .default) throws -> XElement {
        guard data.count <= limits.maxBytes else {
            throw StorageError.invalidResponse("The XML response is larger than \(limits.maxBytes) bytes.")
        }
        guard !containsDeclaration(data) else {
            throw StorageError.invalidResponse("The XML response declares a DTD, which is not allowed.")
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        let builder = TreeBuilder(limits: limits)
        parser.delegate = builder
        let succeeded = parser.parse()
        if let failure = builder.failure { throw failure }
        guard succeeded, let root = builder.root else {
            let reason = parser.parserError.map { " (\(($0 as NSError).code))" } ?? ""
            throw StorageError.invalidResponse("The XML response is malformed\(reason).")
        }
        return root
    }

    /// Case-insensitive search for `<!DOCTYPE` or `<!ENTITY` anywhere in the raw bytes.
    static func containsDeclaration(_ data: Data) -> Bool {
        let patterns: [[UInt8]] = [Array("<!doctype".utf8), Array("<!entity".utf8)]
        return data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= 2 else { return false }
            var index = 0
            while index < bytes.count - 1 {
                if bytes[index] == UInt8(ascii: "<"), bytes[index + 1] == UInt8(ascii: "!") {
                    for pattern in patterns where index + pattern.count <= bytes.count {
                        var matched = true
                        for offset in 2..<pattern.count {
                            let byte = bytes[index + offset]
                            let lowered = (byte >= 65 && byte <= 90) ? byte + 32 : byte
                            if lowered != pattern[offset] { matched = false; break }
                        }
                        if matched { return true }
                    }
                }
                index += 1
            }
            return false
        }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        let limits: XMLLimits
        var stack: [XElement] = []
        var root: XElement?
        var failure: StorageError?
        var elementCount = 0
        var textBytes = 0

        init(limits: XMLLimits) {
            self.limits = limits
        }

        private func fail(_ parser: XMLParser, _ message: String) {
            if failure == nil { failure = StorageError.invalidResponse(message) }
            parser.abortParsing()
        }

        private static func localName(_ name: String) -> String {
            guard let colon = name.lastIndex(of: ":") else { return name }
            return String(name[name.index(after: colon)...])
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard failure == nil else { return }
            elementCount += 1
            guard elementCount <= limits.maxElements else { return fail(parser, "The XML response has too many elements.") }
            guard stack.count < limits.maxDepth else { return fail(parser, "The XML response is nested too deeply.") }
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict where !key.hasPrefix("xmlns") {
                attributes[Self.localName(key)] = value
            }
            stack.append(XElement(name: Self.localName(elementName), attributes: attributes))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard failure == nil, !stack.isEmpty else { return }
            textBytes += string.utf8.count
            guard textBytes <= limits.maxTextBytes else { return fail(parser, "The XML response contains too much text.") }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard failure == nil, !stack.isEmpty else { return }
            textBytes += CDATABlock.count
            guard textBytes <= limits.maxTextBytes else { return fail(parser, "The XML response contains too much text.") }
            stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard failure == nil, var element = stack.popLast() else { return }
            if !element.children.isEmpty, element.text.allSatisfy(\.isWhitespace) { element.text = "" }
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(element)
            }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            fail(parser, "The XML response declares entities, which is not allowed.")
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            fail(parser, "The XML response declares entities, which is not allowed.")
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }
}

/// Minimal XML writer for request bodies. Text is escaped; `\r` becomes `&#xD;` so it survives
/// line-ending normalisation on the server.
public struct XMLWriter: Sendable {
    public private(set) var result = ""

    public init(declaration: Bool = true) {
        if declaration { result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" }
    }

    public mutating func open(_ name: String, attributes: [String: String] = [:]) {
        result += "<" + name
        for key in attributes.keys.sorted() { result += " \(key)=\"\(Self.escape(attributes[key] ?? ""))\"" }
        result += ">"
    }

    public mutating func close(_ name: String) { result += "</\(name)>" }

    public mutating func element(_ name: String, _ text: String) {
        result += "<\(name)>\(Self.escape(text))</\(name)>"
    }

    public var data: Data { Data(result.utf8) }

    public static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            case "\r": output += "&#xD;"
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    /// Whether `text` can be represented in an XML 1.0 document at all.
    public static func isRepresentable(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
            default: false
            }
        }
    }

    /// Indented rendering of a parsed tree (for showing configuration documents).
    public static func prettyPrinted(_ element: XElement, indent: String = "") -> String {
        let attributes = element.attributes.keys.sorted().map { " \($0)=\"\(escape(element.attributes[$0] ?? ""))\"" }.joined()
        if element.children.isEmpty {
            return "\(indent)<\(element.name)\(attributes)>\(escape(element.text))</\(element.name)>"
        }
        let inner = element.children.map { prettyPrinted($0, indent: indent + "  ") }.joined(separator: "\n")
        return "\(indent)<\(element.name)\(attributes)>\n\(inner)\n\(indent)</\(element.name)>"
    }
}

/// Date parsing for storage responses (no shared formatters, locale independent).
public enum StorageDate {
    /// `yyyy-MM-ddTHH:mm:ss[.fraction](Z|±hh:mm)`.
    public static func parseISO8601(_ text: String) -> Date? {
        let bytes = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        guard bytes.count >= 20 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= bytes.count else { return nil }
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " "),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }
        var index = 19
        var fraction = 0.0
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        var offsetSeconds = 0
        if index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "Z"), UInt8(ascii: "z"):
                index += 1
            case UInt8(ascii: "+"), UInt8(ascii: "-"):
                guard let hours = number((index + 1)..<(index + 3)), index + 3 < bytes.count, bytes[index + 3] == UInt8(ascii: ":"),
                      let minutes = number((index + 4)..<(index + 6)) else { return nil }
                offsetSeconds = (hours * 3600 + minutes * 60) * (bytes[index] == UInt8(ascii: "-") ? -1 : 1)
                index += 6
            default:
                return nil
            }
        }
        guard index == bytes.count else { return nil }
        var components = tm()
        components.tm_year = Int32(year - 1900)
        components.tm_mon = Int32(month - 1)
        components.tm_mday = Int32(day)
        components.tm_hour = Int32(hour)
        components.tm_min = Int32(minute)
        components.tm_sec = Int32(second)
        let seconds = timegm(&components)
        return Date(timeIntervalSince1970: TimeInterval(seconds - offsetSeconds) + fraction)
    }
}
