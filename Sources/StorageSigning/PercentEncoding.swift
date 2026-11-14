import Foundation

/// RFC 3986 percent-encoding as required by AWS SigV4 and OSS: only `A–Z a–z 0–9 - _ . ~` (and optionally
/// `/`) stay literal; every other byte of the UTF-8 encoding becomes `%XX` with upper-case hex digits.
/// Nothing is ever normalised (`.`/`..` segments and repeated slashes are preserved).
public enum PercentEncoding {
    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    @inline(__always)
    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }

    public static func encode(_ text: String, keepSlash: Bool) -> String {
        var output = [UInt8]()
        output.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            if isUnreserved(byte) || (keepSlash && byte == UInt8(ascii: "/")) {
                output.append(byte)
            } else {
                output.append(UInt8(ascii: "%"))
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Encodes a decoded URL path, keeping `/`.
    public static func encodePath(_ path: String) -> String { encode(path, keepSlash: true) }

    /// Encodes one query name or value (also encodes `/`).
    public static func encodeQueryComponent(_ text: String) -> String { encode(text, keepSlash: false) }

    /// The query string sent on the wire, in the given order: `name=value` pairs joined by `&`.
    public static func queryString(_ parameters: [QueryParameter]) -> String {
        parameters.map { "\(encodeQueryComponent($0.name))=\(encodeQueryComponent($0.value))" }.joined(separator: "&")
    }

    /// Encoded `(name, value)` pairs sorted bytewise by name, then value.
    static func sortedEncodedPairs(_ parameters: [QueryParameter]) -> [(name: String, value: String)] {
        parameters
            .map { (name: encodeQueryComponent($0.name), value: encodeQueryComponent($0.value)) }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8) }
                return lhs.value.utf8.lexicographicallyPrecedes(rhs.value.utf8)
            }
    }

    /// AWS SigV4 canonical query string: sorted, every pair as `name=value` (empty values keep `=`).
    public static func canonicalQuery(_ parameters: [QueryParameter]) -> String {
        sortedEncodedPairs(parameters).map { "\($0.name)=\($0.value)" }.joined(separator: "&")
    }

    /// Decodes `%XX` escapes (and `+` as space when `plusAsSpace`). Returns nil for malformed escapes or
    /// byte sequences that are not valid UTF-8, so callers can fall back to the raw text.
    public static func decode(_ text: String, plusAsSpace: Bool) -> String? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.utf8.count)
        var iterator = text.utf8.makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case UInt8(ascii: "%"):
                guard let high = iterator.next().flatMap(hexValue), let low = iterator.next().flatMap(hexValue) else { return nil }
                bytes.append(high << 4 | low)
            case UInt8(ascii: "+") where plusAsSpace:
                bytes.append(UInt8(ascii: " "))
            default:
                bytes.append(byte)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
