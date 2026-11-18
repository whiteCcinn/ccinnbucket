import Foundation

/// Constants from RFC 8878.
enum ZstdTables {
    static let maxLiteralLengthCode = 35
    static let maxMatchLengthCode = 52
    static let maxOffsetCode = 31
    static let literalLengthMaxLog = 9
    static let matchLengthMaxLog = 9
    static let offsetMaxLog = 8
    static let blockMaximumSize = 128 * 1024
    static let huffmanMaxBits = 11

    static let literalLengthDefault: [Int16] = [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
                                                -1, -1, -1, -1]
    static let literalLengthDefaultLog = 6
    static let matchLengthDefault: [Int16] = [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                              1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1]
    static let matchLengthDefaultLog = 6
    static let offsetDefault: [Int16] = [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1]
    static let offsetDefaultLog = 5

    static let literalLengthBaseline: [UInt32] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40, 48, 64,
                                                  128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    static let literalLengthExtraBits: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11,
                                                  12, 13, 14, 15, 16]
    static let matchLengthBaseline: [UInt32] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
                                                28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027,
                                                2051, 4099, 8195, 16387, 32771, 65539]
    static let matchLengthExtraBits: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                                1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]

    static func highBit(_ value: UInt64) -> Int { value == 0 ? -1 : 63 - value.leadingZeroBitCount }
}

/// Reads a bitstream backwards (Zstandard FSE and Huffman streams): the last byte holds a 1-bit end marker; bits
/// before the start of the stream read as zeros, and the position may go negative (that is how overflow shows).
struct BackwardBitReader {
    private let bytes: [UInt8]
    /// Bits not yet read lie in [0, offset).
    private(set) var offset: Int

    init(_ bytes: [UInt8]) throws {
        guard let last = bytes.last, last != 0 else { throw DecompressionError.corrupt("bitstream without an end marker") }
        self.bytes = bytes
        offset = bytes.count * 8 - (8 - ZstdTables.highBit(UInt64(last)))
    }

    /// `count` bits (≤ 32).
    mutating func read(_ count: Int) -> UInt32 {
        guard count > 0 else { return 0 }
        offset -= count
        var start = offset
        var bits = count
        if start < 0 {
            bits += start
            start = 0
            guard bits > 0 else { return 0 }
        }
        let value = Self.readLE(bytes, bitOffset: start, count: bits)
        return offset < 0 ? UInt32(truncatingIfNeeded: value << UInt64(-offset)) : UInt32(truncatingIfNeeded: value)
    }

    static func readLE(_ bytes: [UInt8], bitOffset: Int, count: Int) -> UInt64 {
        let first = bitOffset >> 3
        let shift = bitOffset & 7
        let needed = (shift + count + 7) >> 3
        var value: UInt64 = 0
        for index in 0..<needed {
            let position = first + index
            let byte: UInt8 = position >= 0 && position < bytes.count ? bytes[position] : 0
            value |= UInt64(byte) << UInt64(8 * index)
        }
        return (value >> UInt64(shift)) & ((1 << UInt64(count)) - 1)
    }
}

/// Reads a bitstream forwards, least significant bit first (FSE table descriptions).
struct ForwardBitReader {
    private let bytes: [UInt8]
    private(set) var bitOffset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) throws -> UInt32 {
        guard count > 0 else { return 0 }
        guard bitOffset + count <= bytes.count * 8 else { throw DecompressionError.corrupt("FSE table description overruns its block") }
        let value = BackwardBitReader.readLE(bytes, bitOffset: bitOffset, count: count)
        bitOffset += count
        return UInt32(truncatingIfNeeded: value)
    }

    mutating func rewind(_ count: Int) { bitOffset = max(0, bitOffset - count) }

    var bytesConsumed: Int { (bitOffset + 7) / 8 }
}

/// FSE decoding table (RFC 8878 4.1).
struct FSETable: Sendable {
    let accuracyLog: Int
    let symbols: [UInt8]
    let bitCounts: [UInt8]
    let baselines: [UInt16]

    var size: Int { symbols.count }

    /// A table that always decodes `symbol` and reads no bits (RLE mode).
    init(rle symbol: UInt8) {
        accuracyLog = 0
        symbols = [symbol]
        bitCounts = [0]
        baselines = [0]
    }

    init(normalized: [Int16], accuracyLog: Int) throws {
        // Below 5 the spreading step can be even and would not visit every cell.
        guard accuracyLog >= 5, accuracyLog <= 15, !normalized.isEmpty, normalized.count <= 256 else {
            throw DecompressionError.corrupt("invalid FSE table")
        }
        let size = 1 << accuracyLog
        var symbols = [UInt8](repeating: 0, count: size)
        var stateDescriptors = [Int](repeating: 0, count: normalized.count)
        var highThreshold = size
        for (symbol, frequency) in normalized.enumerated() where frequency == -1 {
            highThreshold -= 1
            guard highThreshold >= 0 else { throw DecompressionError.corrupt("FSE distribution overflows its table") }
            symbols[highThreshold] = UInt8(symbol)
            stateDescriptors[symbol] = 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        var position = 0
        var placed = 0
        for (symbol, frequency) in normalized.enumerated() where frequency > 0 {
            stateDescriptors[symbol] = Int(frequency)
            for _ in 0..<Int(frequency) {
                guard placed < highThreshold else { throw DecompressionError.corrupt("FSE distribution overflows its table") }
                symbols[position] = UInt8(symbol)
                placed += 1
                // Terminates: `step` is odd, so it visits every cell, and highThreshold ≥ 1 here.
                repeat { position = (position + step) & mask } while position >= highThreshold
            }
        }
        guard placed == highThreshold, position == 0 else { throw DecompressionError.corrupt("FSE distribution does not fill its table") }
        var bitCounts = [UInt8](repeating: 0, count: size)
        var baselines = [UInt16](repeating: 0, count: size)
        for index in 0..<size {
            let symbol = Int(symbols[index])
            let descriptor = stateDescriptors[symbol]
            stateDescriptors[symbol] += 1
            let bits = accuracyLog - ZstdTables.highBit(UInt64(descriptor))
            guard bits >= 0, bits <= accuracyLog else { throw DecompressionError.corrupt("invalid FSE state") }
            bitCounts[index] = UInt8(bits)
            let baseline = (descriptor << bits) - size
            guard baseline >= 0, baseline < size else { throw DecompressionError.corrupt("invalid FSE state") }
            baselines[index] = UInt16(baseline)
        }
        self.accuracyLog = accuracyLog
        self.symbols = symbols
        self.bitCounts = bitCounts
        self.baselines = baselines
    }

    /// Reads a table description (RFC 8878 4.1.1); returns the table and the bytes it used.
    static func read(_ bytes: [UInt8], maxAccuracyLog: Int, maxSymbol: Int) throws -> (FSETable, Int) {
        var reader = ForwardBitReader(bytes)
        let accuracyLog = Int(try reader.read(4)) + 5
        guard accuracyLog <= maxAccuracyLog else { throw DecompressionError.corrupt("FSE accuracy log too large") }
        var remaining = (1 << accuracyLog) + 1
        var frequencies: [Int16] = []
        while remaining > 1 {
            guard frequencies.count <= maxSymbol else { throw DecompressionError.corrupt("FSE table has too many symbols") }
            let bits = ZstdTables.highBit(UInt64(remaining)) + 1
            var value = Int(try reader.read(bits))
            let lowerMask = (1 << (bits - 1)) - 1
            let threshold = (1 << bits) - 1 - remaining
            if value & lowerMask < threshold {
                reader.rewind(1)
                value &= lowerMask
            } else if value > lowerMask {
                value -= threshold
            }
            let probability = value - 1
            remaining -= probability < 0 ? 1 : probability
            guard remaining >= 1 else { throw DecompressionError.corrupt("FSE probabilities exceed the table") }
            frequencies.append(Int16(probability))
            if probability == 0 {
                while true {
                    let repeats = Int(try reader.read(2))
                    for _ in 0..<repeats { frequencies.append(0) }
                    guard frequencies.count <= maxSymbol + 1 else { throw DecompressionError.corrupt("FSE table has too many symbols") }
                    if repeats != 3 { break }
                }
            }
        }
        guard remaining == 1, frequencies.count <= maxSymbol + 1 else { throw DecompressionError.corrupt("invalid FSE table description") }
        return (try FSETable(normalized: frequencies, accuracyLog: accuracyLog), reader.bytesConsumed)
    }

    static let literalLengthDefault = try! FSETable(normalized: ZstdTables.literalLengthDefault, accuracyLog: ZstdTables.literalLengthDefaultLog)
    static let matchLengthDefault = try! FSETable(normalized: ZstdTables.matchLengthDefault, accuracyLog: ZstdTables.matchLengthDefaultLog)
    static let offsetDefault = try! FSETable(normalized: ZstdTables.offsetDefault, accuracyLog: ZstdTables.offsetDefaultLog)
}

/// Huffman decoding table for literals (RFC 8878 4.2), indexed by `maxBits` bits read backwards.
struct HuffmanTable: Sendable {
    let maxBits: Int
    let symbols: [UInt8]
    let bitCounts: [UInt8]

    /// Reads a Huffman tree description; returns the table and the bytes it used.
    static func read(_ bytes: [UInt8]) throws -> (HuffmanTable, Int) {
        guard let header = bytes.first else { throw DecompressionError.corrupt("missing Huffman tree description") }
        var weights: [UInt8]
        var used: Int
        if header >= 128 {
            let count = Int(header) - 127
            let byteCount = (count + 1) / 2
            guard bytes.count >= 1 + byteCount else { throw DecompressionError.corrupt("Huffman weights overrun the block") }
            weights = (0..<count).map { index in
                let byte = bytes[1 + index / 2]
                return index % 2 == 0 ? byte >> 4 : byte & 0x0F
            }
            used = 1 + byteCount
        } else {
            let size = Int(header)
            guard size > 0, bytes.count >= 1 + size else { throw DecompressionError.corrupt("Huffman weights overrun the block") }
            weights = try decodeWeights(Array(bytes[1...size]))
            used = 1 + size
        }
        return (try HuffmanTable(weights: weights), used)
    }

    /// FSE-compressed weights: two interleaved states over one backward bitstream.
    private static func decodeWeights(_ bytes: [UInt8]) throws -> [UInt8] {
        let (table, headerSize) = try FSETable.read(bytes, maxAccuracyLog: 6, maxSymbol: 255)
        guard headerSize < bytes.count else { throw DecompressionError.corrupt("Huffman weights stream is empty") }
        var reader = try BackwardBitReader(Array(bytes[headerSize...]))
        var state1 = Int(reader.read(table.accuracyLog))
        var state2 = Int(reader.read(table.accuracyLog))
        var weights: [UInt8] = []
        func step(_ state: inout Int) -> UInt8 {
            let symbol = table.symbols[state]
            state = Int(table.baselines[state]) + Int(reader.read(Int(table.bitCounts[state])))
            return symbol
        }
        while true {
            guard weights.count < 255 else { throw DecompressionError.corrupt("too many Huffman weights") }
            weights.append(step(&state1))
            if reader.offset < 0 {
                weights.append(table.symbols[state2])
                break
            }
            weights.append(step(&state2))
            if reader.offset < 0 {
                weights.append(table.symbols[state1])
                break
            }
        }
        guard weights.count <= 255 else { throw DecompressionError.corrupt("too many Huffman weights") }
        return weights
    }

    init(weights: [UInt8]) throws {
        guard !weights.isEmpty, weights.count <= 255 else { throw DecompressionError.corrupt("invalid Huffman weights") }
        var sum: UInt64 = 0
        for weight in weights {
            guard weight <= ZstdTables.huffmanMaxBits else { throw DecompressionError.corrupt("Huffman weight too large") }
            if weight > 0 { sum += 1 << UInt64(weight - 1) }
        }
        guard sum > 0 else { throw DecompressionError.corrupt("all Huffman weights are zero") }
        let maxBits = ZstdTables.highBit(sum) + 1
        guard maxBits <= ZstdTables.huffmanMaxBits else { throw DecompressionError.corrupt("Huffman code too deep") }
        let leftOver = (UInt64(1) << UInt64(maxBits)) - sum
        guard leftOver & (leftOver - 1) == 0 else { throw DecompressionError.corrupt("Huffman weights do not complete the tree") }
        let lastWeight = ZstdTables.highBit(leftOver) + 1
        var bits = weights.map { $0 > 0 ? UInt8(maxBits + 1 - Int($0)) : 0 }
        bits.append(UInt8(maxBits + 1 - lastWeight))

        var rankCount = [Int](repeating: 0, count: maxBits + 2)
        for count in bits { rankCount[Int(count)] += 1 }
        let size = 1 << maxBits
        var rankIndex = [Int](repeating: 0, count: maxBits + 2)
        var bitCounts = [UInt8](repeating: 0, count: size)
        rankIndex[maxBits] = 0
        var length = maxBits
        while length >= 1 {
            rankIndex[length - 1] = rankIndex[length] + rankCount[length] * (1 << (maxBits - length))
            guard rankIndex[length - 1] <= size else { throw DecompressionError.corrupt("invalid Huffman tree") }
            for index in rankIndex[length]..<rankIndex[length - 1] { bitCounts[index] = UInt8(length) }
            length -= 1
        }
        guard rankIndex[0] == size else { throw DecompressionError.corrupt("invalid Huffman tree") }
        var symbols = [UInt8](repeating: 0, count: size)
        for (symbol, count) in bits.enumerated() where count > 0 {
            let code = rankIndex[Int(count)]
            let span = 1 << (maxBits - Int(count))
            guard code + span <= size else { throw DecompressionError.corrupt("invalid Huffman tree") }
            for index in code..<(code + span) { symbols[index] = UInt8(symbol) }
            rankIndex[Int(count)] += span
        }
        self.maxBits = maxBits
        self.symbols = symbols
        self.bitCounts = bitCounts
    }

    /// Decodes one stream to exactly its symbols (the stream must be consumed exactly).
    func decodeStream(_ bytes: [UInt8], into output: inout [UInt8], limit: Int) throws {
        var reader = try BackwardBitReader(bytes)
        let mask = (1 << maxBits) - 1
        var state = Int(reader.read(maxBits))
        while reader.offset > -maxBits {
            guard output.count < limit else { throw DecompressionError.corrupt("Huffman stream longer than its literals") }
            let symbol = symbols[state]
            let count = Int(bitCounts[state])
            output.append(symbol)
            let rest = Int(reader.read(count))
            state = ((state << count) + rest) & mask
        }
        guard reader.offset == -maxBits else { throw DecompressionError.corrupt("Huffman stream not consumed exactly") }
    }
}
