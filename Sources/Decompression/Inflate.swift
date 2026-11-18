import Foundation

/// Canonical Huffman decoding table for DEFLATE: indexed by the next `bits` input bits (LSB first), each entry
/// packs `symbol << 8 | codeLength`; a zero length marks an unused code.
struct DeflateHuffmanTable: Sendable {
    let entries: [UInt32]
    /// Longest code length (0 when the code has no symbols).
    let bits: Int

    /// - Throws: `.corrupt` for over-subscribed code lengths or lengths above 15.
    init(lengths: [UInt8]) throws {
        var counts = [Int](repeating: 0, count: 16)
        var maxLength = 0
        for length in lengths {
            guard length <= 15 else { throw DecompressionError.corrupt("Huffman code longer than 15 bits") }
            if length > 0 {
                counts[Int(length)] += 1
                maxLength = max(maxLength, Int(length))
            }
        }
        var left = 1
        for length in 1..<16 {
            left <<= 1
            left -= counts[length]
            if left < 0 { throw DecompressionError.corrupt("over-subscribed Huffman code") }
        }
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1..<16 {
            code = (code + counts[length - 1]) << 1
            nextCode[length] = code
        }
        let size = 1 << maxLength
        var table = [UInt32](repeating: 0, count: maxLength == 0 ? 1 : size)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let len = Int(length)
            let assigned = nextCode[len]
            nextCode[len] += 1
            var reversed = 0
            for bit in 0..<len where assigned & (1 << bit) != 0 { reversed |= 1 << (len - 1 - bit) }
            var index = reversed
            while index < size {
                table[index] = UInt32(symbol) << 8 | UInt32(len)
                index += 1 << len
            }
        }
        entries = table
        bits = maxLength
    }

    static let fixedLiterals: DeflateHuffmanTable = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for index in 144..<256 { lengths[index] = 9 }
        for index in 256..<280 { lengths[index] = 7 }
        return try! DeflateHuffmanTable(lengths: lengths)
    }()

    static let fixedDistances: DeflateHuffmanTable = try! DeflateHuffmanTable(lengths: [UInt8](repeating: 5, count: 32))
}

/// Resumable raw DEFLATE decoder (RFC 1951). It reads from an `InputBuffer` without consuming bytes until a
/// symbol (or block header) is complete, so running out of input in the middle of anything rolls back cleanly.
struct Inflater {
    private enum Block {
        case header
        case stored(remaining: Int)
        case huffman(literals: DeflateHuffmanTable, distances: DeflateHuffmanTable)
    }

    enum Result {
        /// The final block ended; `input` is positioned at the first byte after the stream.
        case endOfStream
        case needsInput
        case outputFull
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
                                            163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                                              2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
    static let windowSize = 1 << 15

    private var block: Block = .header
    private var isFinalBlock = false
    private var bitBuffer: UInt64 = 0
    private var bitCount = 0
    /// Recent output: at least the last 32 KiB once that much was produced.
    private var history: [UInt8] = []
    /// `history` index of the first byte not yet handed to the caller.
    private var delivered = 0

    var retainedBytes: Int { history.count }

    /// Decodes until the stream ends, input runs out, or `maxOutput` new bytes were produced; new bytes go to `output`.
    mutating func inflate(_ input: inout InputBuffer, into output: inout Data, maxOutput: Int, crc: inout CRC32) throws -> Result {
        let result = try run(&input, limit: max(1, maxOutput))
        if delivered < history.count {
            history.withUnsafeBufferPointer { all in
                let fresh = UnsafeBufferPointer(rebasing: all[delivered...])
                output.append(fresh)
                crc.update(fresh)
            }
            delivered = history.count
        }
        if history.count > 8 * Self.windowSize {
            history.removeFirst(history.count - Self.windowSize)
            delivered = history.count
        }
        return result
    }

    // MARK: Bits

    /// Reader over the unconsumed input; nothing is consumed until `commit`.
    private struct Cursor {
        var position = 0
        var bitBuffer: UInt64
        var bitCount: Int
    }

    private func refill(_ cursor: inout Cursor, _ input: borrowing InputBuffer) {
        while cursor.bitCount <= 56, let byte = input.byte(at: cursor.position) {
            cursor.bitBuffer |= UInt64(byte) << UInt64(cursor.bitCount)
            cursor.bitCount += 8
            cursor.position += 1
        }
    }

    /// `count` bits (≤ 32), or nil when the input does not have them yet.
    private func read(_ count: Int, _ cursor: inout Cursor, _ input: borrowing InputBuffer) -> Int? {
        if cursor.bitCount < count { refill(&cursor, input) }
        guard cursor.bitCount >= count else { return nil }
        let value = Int(cursor.bitBuffer & ((1 << UInt64(count)) - 1))
        cursor.bitBuffer >>= UInt64(count)
        cursor.bitCount -= count
        return value
    }

    /// The next Huffman symbol: nil when more input is needed; throws for unused codes.
    private func decodeSymbol(_ table: DeflateHuffmanTable, _ cursor: inout Cursor, _ input: borrowing InputBuffer) throws -> Int? {
        guard table.bits > 0 else { throw DecompressionError.corrupt("use of an empty Huffman code") }
        if cursor.bitCount < table.bits { refill(&cursor, input) }
        let index = Int(cursor.bitBuffer & ((1 << UInt64(table.bits)) - 1))
        let entry = table.entries[index]
        let length = Int(entry & 0xFF)
        guard length > 0, length <= cursor.bitCount else {
            if cursor.bitCount >= table.bits { throw DecompressionError.corrupt("invalid Huffman code") }
            return nil
        }
        cursor.bitBuffer >>= UInt64(length)
        cursor.bitCount -= length
        return Int(entry >> 8)
    }

    private mutating func commit(_ cursor: Cursor, _ input: inout InputBuffer) {
        input.consume(cursor.position)
        bitBuffer = cursor.bitBuffer
        bitCount = cursor.bitCount
    }

    // MARK: Decoding

    private mutating func run(_ input: inout InputBuffer, limit: Int) throws -> Result {
        let startCount = history.count
        while true {
            switch block {
            case .header:
                var cursor = Cursor(bitBuffer: bitBuffer, bitCount: bitCount)
                guard let parsed = try parseHeader(&cursor, input) else { return .needsInput }
                commit(cursor, &input)
                block = parsed
            case let .stored(remaining):
                if remaining == 0 {
                    if let end = finishBlock(&input) { return end }
                    continue
                }
                guard history.count - startCount < limit else { return .outputFull }
                var left = remaining
                // Whole bytes still in the bit buffer come first (the buffer is byte-aligned in stored blocks).
                while left > 0, bitCount >= 8 {
                    history.append(UInt8(truncatingIfNeeded: bitBuffer))
                    bitBuffer >>= 8
                    bitCount -= 8
                    left -= 1
                }
                let take = min(left, input.available, max(0, limit - (history.count - startCount)))
                if take > 0 {
                    input.bytes.withUnsafeBufferPointer { all in
                        history.append(contentsOf: all[input.start..<(input.start + take)])
                    }
                    input.consume(take)
                    left -= take
                }
                block = .stored(remaining: left)
                if left > 0 {
                    if input.isEmpty { return .needsInput }
                    return .outputFull
                }
            case let .huffman(literals, distances):
                let result = try decodeHuffman(literals, distances, &input, limit: limit, startCount: startCount)
                switch result {
                case .endOfBlock:
                    if let end = finishBlock(&input) { return end }
                case .needsInput:
                    return .needsInput
                case .outputFull:
                    return .outputFull
                }
            }
        }
    }

    /// After a block: the next header, or the end of the stream (returning unused whole bytes to the input).
    private mutating func finishBlock(_ input: inout InputBuffer) -> Result? {
        block = .header
        guard isFinalBlock else { return nil }
        // Bits left in the last byte are padding; whole bytes in the buffer belong to what follows the stream.
        let wholeBytes = bitCount / 8
        input.unconsume(wholeBytes)
        bitBuffer = 0
        bitCount = 0
        return .endOfStream
    }

    private mutating func parseHeader(_ cursor: inout Cursor, _ input: borrowing InputBuffer) throws -> Block? {
        guard let final = read(1, &cursor, input), let type = read(2, &cursor, input) else { return nil }
        switch type {
        case 0:
            // Stored: skip to a byte boundary, then LEN and its one's complement.
            let skip = cursor.bitCount % 8
            cursor.bitBuffer >>= UInt64(skip)
            cursor.bitCount -= skip
            guard let length = read(16, &cursor, input), let complement = read(16, &cursor, input) else { return nil }
            guard length == ~complement & 0xFFFF else { throw DecompressionError.corrupt("stored block length check failed") }
            isFinalBlock = final == 1
            return .stored(remaining: length)
        case 1:
            isFinalBlock = final == 1
            return .huffman(literals: .fixedLiterals, distances: .fixedDistances)
        case 2:
            guard let tables = try parseDynamicTables(&cursor, input) else { return nil }
            isFinalBlock = final == 1
            return .huffman(literals: tables.0, distances: tables.1)
        default:
            throw DecompressionError.corrupt("reserved deflate block type")
        }
    }

    private func parseDynamicTables(_ cursor: inout Cursor, _ input: borrowing InputBuffer) throws -> (DeflateHuffmanTable, DeflateHuffmanTable)? {
        guard let hlit = read(5, &cursor, input), let hdist = read(5, &cursor, input), let hclen = read(4, &cursor, input) else { return nil }
        let literalCount = hlit + 257
        let distanceCount = hdist + 1
        guard literalCount <= 286, distanceCount <= 30 else { throw DecompressionError.corrupt("too many Huffman codes") }
        var codeLengthLengths = [UInt8](repeating: 0, count: 19)
        for index in 0..<(hclen + 4) {
            guard let length = read(3, &cursor, input) else { return nil }
            codeLengthLengths[Self.codeLengthOrder[index]] = UInt8(length)
        }
        let codeLengthTable = try DeflateHuffmanTable(lengths: codeLengthLengths)
        var lengths: [UInt8] = []
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            guard let symbol = try decodeSymbol(codeLengthTable, &cursor, input) else { return nil }
            switch symbol {
            case 0...15:
                lengths.append(UInt8(symbol))
            case 16:
                guard let previous = lengths.last else { throw DecompressionError.corrupt("repeat with no previous code length") }
                guard let extra = read(2, &cursor, input) else { return nil }
                lengths.append(contentsOf: repeatElement(previous, count: 3 + extra))
            case 17:
                guard let extra = read(3, &cursor, input) else { return nil }
                lengths.append(contentsOf: repeatElement(0, count: 3 + extra))
            case 18:
                guard let extra = read(7, &cursor, input) else { return nil }
                lengths.append(contentsOf: repeatElement(0, count: 11 + extra))
            default:
                throw DecompressionError.corrupt("invalid code length symbol")
            }
            guard lengths.count <= literalCount + distanceCount else { throw DecompressionError.corrupt("code lengths overflow") }
        }
        guard lengths[256] != 0 else { throw DecompressionError.corrupt("no end-of-block code") }
        let literals = try DeflateHuffmanTable(lengths: Array(lengths[0..<literalCount]))
        let distances = try DeflateHuffmanTable(lengths: Array(lengths[literalCount...]))
        return (literals, distances)
    }

    private enum HuffmanStop {
        case endOfBlock
        case needsInput
        case outputFull
    }

    private mutating func decodeHuffman(_ literals: DeflateHuffmanTable, _ distances: DeflateHuffmanTable, _ input: inout InputBuffer,
                                        limit: Int, startCount: Int) throws -> HuffmanStop {
        var cursor = Cursor(bitBuffer: bitBuffer, bitCount: bitCount)
        defer { commit(cursor, &input) }
        while true {
            guard history.count - startCount < limit else { return .outputFull }
            let checkpoint = cursor
            guard let symbol = try decodeSymbol(literals, &cursor, input) else {
                cursor = checkpoint
                return .needsInput
            }
            if symbol < 256 {
                history.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return .endOfBlock }
            let lengthIndex = symbol - 257
            guard lengthIndex < Self.lengthBase.count else { throw DecompressionError.corrupt("invalid length symbol") }
            guard let lengthExtra = read(Self.lengthExtra[lengthIndex], &cursor, input),
                  let distanceSymbol = try decodeSymbol(distances, &cursor, input) else {
                cursor = checkpoint
                return .needsInput
            }
            guard distanceSymbol < Self.distanceBase.count else { throw DecompressionError.corrupt("invalid distance symbol") }
            guard let distanceExtra = read(Self.distanceExtra[distanceSymbol], &cursor, input) else {
                cursor = checkpoint
                return .needsInput
            }
            let length = Self.lengthBase[lengthIndex] + lengthExtra
            let distance = Self.distanceBase[distanceSymbol] + distanceExtra
            guard distance <= history.count else { throw DecompressionError.corrupt("distance too far back") }
            // Byte by byte: overlapping copies repeat recent output, and no slice of `history` stays alive while
            // appending (that would copy the whole buffer on every match).
            let from = history.count - distance
            for index in 0..<length { history.append(history[from + index]) }
        }
    }
}

extension InputBuffer {
    /// Gives back `count` bytes consumed by the last read (the inflater reads ahead past the end of the stream).
    mutating func unconsume(_ count: Int) {
        rewind(count)
    }
}
