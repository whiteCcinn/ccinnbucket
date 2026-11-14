import Foundation

/// A JSON value for the MCP JSON-RPC layer (no third-party dependencies).
public enum JSONValue: Sendable, Hashable, Codable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Nesting deeper than this is rejected before decoding (protects the recursive decoder's stack).
    public static let maximumDepth = 64

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public struct ParseError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Parses one JSON document (fragments allowed), rejecting excessive nesting.
    public static func parse(_ data: Data) throws -> JSONValue {
        guard depth(of: data) <= maximumDepth else { throw ParseError(message: "JSON nested deeper than \(maximumDepth) levels") }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ParseError(message: "Invalid JSON")
        }
    }

    /// Maximum bracket nesting, ignoring brackets inside strings.
    static func depth(of data: Data) -> Int {
        var depth = 0
        var maximum = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                maximum = max(maximum, depth)
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return maximum
    }

    /// Compact UTF-8 encoding (sorted keys, no raw newlines).
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var description: String { String(decoding: encoded(), as: UTF8.self) }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    public var boolValue: Bool? { if case let .bool(value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case let .array(value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case let .object(value) = self { value } else { nil } }

    public var intValue: Int64? {
        switch self {
        case let .int(value): return value
        case let .double(value) where value.rounded() == value && abs(value) < 9.0e15: return Int64(value)
        default: return nil
        }
    }

    // Convenience constructors.
    public static func from(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
    public static func from(_ number: Int64?) -> JSONValue { number.map(JSONValue.int) ?? .null }
    public static func from(_ number: Int) -> JSONValue { .int(Int64(number)) }

    public static func from(_ date: Date?) -> JSONValue {
        guard let date else { return .null }
        return .string(date.formatted(.iso8601))
    }
}

/// Splits a byte stream into newline-delimited messages with a size bound. Oversized lines are reported
/// once and skipped up to the next newline, so one bad message never stops the server.
public struct MCPLineBuffer: Sendable {
    public enum Line: Sendable, Hashable {
        case message(Data)
        case oversized
    }

    public let maximumLineBytes: Int
    private var buffer = Data()
    private var discarding = false

    public init(maximumLineBytes: Int = MCPLimits.maximumMessageBytes) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    public mutating func append(_ data: Data) -> [Line] {
        var lines: [Line] = []
        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            let piece = data[start..<newline]
            if discarding {
                discarding = false
                buffer.removeAll(keepingCapacity: true)
                lines.append(.oversized)
            } else if buffer.count + piece.count > maximumLineBytes {
                buffer.removeAll(keepingCapacity: true)
                lines.append(.oversized)
            } else {
                buffer.append(piece)
                if let line = Self.trimmed(buffer) { lines.append(.message(line)) }
                buffer.removeAll(keepingCapacity: true)
            }
            start = data.index(after: newline)
        }
        let rest = data[start...]
        if !discarding {
            if buffer.count + rest.count > maximumLineBytes {
                buffer.removeAll(keepingCapacity: false)
                discarding = true
            } else {
                buffer.append(rest)
            }
        }
        return lines
    }

    /// The final unterminated line at end of input, if any.
    public mutating func finish() -> Line? {
        defer {
            buffer.removeAll()
            discarding = false
        }
        if discarding { return .oversized }
        return Self.trimmed(buffer).map(Line.message)
    }

    private static func trimmed(_ data: Data) -> Data? {
        var end = data.endIndex
        while end > data.startIndex, [UInt8(ascii: "\r"), UInt8(ascii: " "), UInt8(ascii: "\t")].contains(data[data.index(before: end)]) {
            end = data.index(before: end)
        }
        var start = data.startIndex
        while start < end, [UInt8(ascii: " "), UInt8(ascii: "\t")].contains(data[start]) { start = data.index(after: start) }
        return start < end ? Data(data[start..<end]) : nil
    }
}

public enum MCPLimits {
    /// Largest accepted JSON-RPC message.
    public static let maximumMessageBytes = 4 << 20
    /// Largest tool result text.
    public static let maximumResultBytes = 256 << 10
    public static let defaultItems = 200
    public static let maximumItems = 1_000
    public static let defaultTextBytes = 64 << 10
    public static let maximumTextBytes = 256 << 10
    public static let maximumPutBytes = 1 << 20
    public static let maximumDeleteKeys = 100
    public static let callTimeout: TimeInterval = 30

    /// Shrinks the largest array (or string) of `object` until its encoding fits, marking it `truncated`.
    public static func fit(_ object: [String: JSONValue], limit: Int = maximumResultBytes) -> JSONValue {
        var current = object
        guard JSONValue.object(current).encoded().count > limit else { return .object(current) }
        current["truncated"] = .bool(true)
        current["truncationNote"] = .string("The result was shortened to fit \(limit / 1024) KB; narrow the request (prefix, max_keys, max_bytes).")
        let budget = limit - 64
        for _ in 0..<4 {
            guard JSONValue.object(current).encoded().count > budget else { break }
            let candidates = current.compactMap { key, value -> (String, Int)? in
                switch value {
                case .array, .string: return (key, value.encoded().count)
                default: return nil
                }
            }
            guard let (key, _) = candidates.max(by: { $0.1 < $1.1 }), let value = current[key] else { break }
            switch value {
            case let .array(items):
                var low = 0
                var high = items.count
                while low < high {
                    let mid = (low + high + 1) / 2
                    var trial = current
                    trial[key] = .array(Array(items.prefix(mid)))
                    if JSONValue.object(trial).encoded().count <= budget { low = mid } else { high = mid - 1 }
                }
                current[key] = .array(Array(items.prefix(low)))
            case let .string(text):
                var low = 0
                var high = text.count
                while low < high {
                    let mid = (low + high + 1) / 2
                    var trial = current
                    trial[key] = .string(String(text.prefix(mid)))
                    if JSONValue.object(trial).encoded().count <= budget { low = mid } else { high = mid - 1 }
                }
                current[key] = .string(String(text.prefix(low)))
            default:
                break
            }
        }
        return .object(current)
    }
}
