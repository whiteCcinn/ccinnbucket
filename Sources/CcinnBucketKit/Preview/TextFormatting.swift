import Foundation

/// Indents JSON for reading without parsing it: tokens (numbers, strings, escapes, key order) stay exactly as they are,
/// so it also works on the truncated beginning of a large file. O(n), never fails.
public enum JSONIndenter {
    /// Nesting deeper than this is not indented further (indentation would otherwise grow with the square of the input).
    public static let maximumDepth = 32
    /// When the indented text would be more than this many times the input, the input is returned as it is.
    public static let maximumGrowth = 4

    public static func format(_ text: String, indent: Int = 2) -> String {
        let input = Array(text.utf8)
        let budget = input.count * maximumGrowth + 4_096
        var output: [UInt8] = []
        output.reserveCapacity(input.count + input.count / 4)
        var level = 0
        var index = 0
        let space = UInt8(ascii: " ")

        func newline() {
            output.append(UInt8(ascii: "\n"))
            output.append(contentsOf: repeatElement(space, count: min(level, maximumDepth) * indent))
        }

        while index < input.count {
            let byte = input[index]
            switch byte {
            case UInt8(ascii: "\""):
                // Copy the string verbatim up to its closing quote (or the end of a truncated input).
                output.append(byte)
                index += 1
                while index < input.count {
                    let next = input[index]
                    output.append(next)
                    index += 1
                    if next == UInt8(ascii: "\\") {
                        if index < input.count {
                            output.append(input[index])
                            index += 1
                        }
                    } else if next == UInt8(ascii: "\"") {
                        break
                    }
                }
                continue
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let closer = byte == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                var lookahead = index + 1
                while lookahead < input.count, isWhitespace(input[lookahead]) { lookahead += 1 }
                output.append(byte)
                if lookahead < input.count, input[lookahead] == closer {
                    output.append(closer)
                    index = lookahead + 1
                    continue
                }
                level += 1
                newline()
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                level = max(0, level - 1)
                if !output.isEmpty { newline() }
                output.append(byte)
            case UInt8(ascii: ","):
                output.append(byte)
                newline()
            case UInt8(ascii: ":"):
                output.append(byte)
                output.append(space)
            default:
                if !isWhitespace(byte) { output.append(byte) }
            }
            index += 1
            // Hostile or odd input (thousands of brackets): show it as it is rather than an enormous text.
            if output.count > budget { return text }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Removes whitespace outside strings: the inverse of `format` for minified JSON (tokens stay exactly as they are).
    public static func compact(_ text: String) -> String {
        let input = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == UInt8(ascii: "\"") {
                output.append(byte)
                index += 1
                while index < input.count {
                    let next = input[index]
                    output.append(next)
                    index += 1
                    if next == UInt8(ascii: "\\") {
                        if index < input.count {
                            output.append(input[index])
                            index += 1
                        }
                    } else if next == UInt8(ascii: "\"") {
                        break
                    }
                }
                continue
            }
            if !isWhitespace(byte) { output.append(byte) }
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

/// Very long lines (minified JSON or JavaScript, CSV without line breaks) make text views lay out megabytes as one
/// paragraph on every change, which hangs the app. These helpers find them and cut them for display.
public enum TextLines {
    /// Lines longer than this are cut for display and are not edited as they are.
    public static let displayLimit = 50_000

    /// Length of the longest line, in UTF-8 bytes.
    public static func longestLine(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                longest = max(longest, current)
                current = 0
            } else {
                current += 1
            }
        }
        return max(longest, current)
    }

    /// The text with every line longer than `limit` cut to `limit` characters and a note of how much was left out.
    public static func cuttingLongLines(_ text: String, limit: Int = displayLimit) -> (text: String, linesCut: Int) {
        guard longestLine(text) > limit else { return (text, 0) }
        var linesCut = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard line.utf8.count > limit else { return line }
            linesCut += 1
            let kept = line.prefix(limit)
            return kept + " … [\(line.count - kept.count) more characters]"
        }
        return (lines.joined(separator: "\n"), linesCut)
    }
}

public enum TextSniffer {
    /// Bytes inspected to decide whether content is text.
    public static let sampleSize = 8_192

    /// NUL bytes, or more than 10% control characters, in the first 8 KiB.
    public static func isLikelyBinary(_ data: Data) -> Bool {
        let sample = data.prefix(sampleSize)
        guard !sample.isEmpty else { return false }
        var control = 0
        for byte in sample {
            if byte == 0 { return true }
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D, byte != 0x0C, byte != 0x1B { control += 1 }
        }
        return control * 10 > sample.count
    }

    /// The text when `data` is entirely valid UTF-8, otherwise `nil` (editing is only offered then, so saving
    /// writes back exactly the bytes that were shown).
    public static func strictUTF8(_ data: Data) -> String? {
        // Decoding replaces invalid sequences with U+FFFD, so the text is exact only if it encodes back to the same
        // bytes (this also keeps a byte-order mark, which `String(data:encoding:)` may drop).
        let text = String(decoding: data, as: UTF8.self)
        return text.utf8.elementsEqual(data) ? text : nil
    }

    /// Text for display: invalid sequences become U+FFFD; a multi-byte character cut off at the end is dropped.
    public static func displayText(_ data: Data) -> String {
        if let text = strictUTF8(data) { return text }
        for trim in 1...3 where data.count > trim {
            if let text = strictUTF8(data.dropLast(trim)) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `hexdump -C` style dump for binary content.
public enum HexDump {
    public static func format(_ data: Data, limit: Int) -> String {
        let shown = data.prefix(max(0, limit))
        var lines: [String] = []
        lines.reserveCapacity(shown.count / 16 + 2)
        let bytes = [UInt8](shown)
        let digits = Array("0123456789abcdef".utf8)
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var line = [UInt8](String(format: "%08x", offset).utf8)
            line += [0x20, 0x20]
            for column in 0..<16 {
                if column < row.count {
                    let byte = row[row.startIndex + column]
                    line += [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)], 0x20]
                } else {
                    line += [0x20, 0x20, 0x20]
                }
                if column == 7 { line.append(0x20) }
            }
            line.append(0x20)
            line.append(UInt8(ascii: "|"))
            line += row.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: ".") }
            line.append(UInt8(ascii: "|"))
            lines.append(String(decoding: line, as: UTF8.self))
            offset += 16
        }
        var text = lines.joined(separator: "\n")
        if data.count > shown.count { text += "\n… \(data.count - shown.count) more bytes" }
        return text
    }
}
