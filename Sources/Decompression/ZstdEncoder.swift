import Foundation

/// Zstandard writer (RFC 8878): one frame with the content size and an XXH64 checksum. Blocks are compressed with a
/// greedy hash-table LZ77 matcher; literals are stored raw and sequences use the three predefined FSE tables
/// (Symbol_Compression_Modes = 0); no repeat-offset codes are emitted. A block that would not shrink is stored raw,
/// and a block of one repeated byte becomes an RLE block.
enum ZstdEncoder {
    static let windowLog = 20
    private static let minimumMatch = 4
    private static let hashLog = 17

    static func compress(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        let size = input.count
        var output: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        let singleSegment = size <= 1 << windowLog
        let contentSizeFlag: UInt8
        let contentSizeBytes: [UInt8]
        if singleSegment, size < 256 {
            contentSizeFlag = 0
            contentSizeBytes = [UInt8(size)]
        } else if size >= 256, size < 65_536 + 256 {
            contentSizeFlag = 1
            contentSizeBytes = littleEndian(UInt64(size - 256), count: 2)
        } else if UInt64(size) <= UInt64(UInt32.max) {
            contentSizeFlag = 2
            contentSizeBytes = littleEndian(UInt64(size), count: 4)
        } else {
            contentSizeFlag = 3
            contentSizeBytes = littleEndian(UInt64(size), count: 8)
        }
        output.append(contentSizeFlag << 6 | (singleSegment ? 0x20 : 0) | 0x04)
        if !singleSegment { output.append(UInt8((windowLog - 10) << 3)) }
        output += contentSizeBytes

        let maximumOffset = singleSegment ? max(size, 1) : 1 << windowLog
        var table = [Int32](repeating: -1, count: 1 << hashLog)
        if size == 0 {
            output += [0x01, 0x00, 0x00] // Last raw block, size 0.
        }
        var blockStart = 0
        while blockStart < size {
            let blockEnd = min(blockStart + ZstdTables.blockMaximumSize, size)
            encodeBlock(input, blockStart..<blockEnd, isLast: blockEnd == size, maximumOffset: maximumOffset, table: &table, into: &output)
            blockStart = blockEnd
        }
        output += littleEndian(XXH64.hash(input) & 0xFFFF_FFFF, count: 4)
        return Data(output)
    }

    private static func littleEndian(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * $0)) }
    }

    private static func blockHeader(last: Bool, type: Int, size: Int) -> [UInt8] {
        littleEndian(UInt64((last ? 1 : 0) | type << 1 | size << 3), count: 3)
    }

    private struct Sequence {
        var literalLength: Int
        var offset: Int
        var matchLength: Int
    }

    private static func read32(_ input: [UInt8], _ index: Int) -> UInt32 {
        UInt32(input[index]) | UInt32(input[index + 1]) << 8 | UInt32(input[index + 2]) << 16 | UInt32(input[index + 3]) << 24
    }

    private static func encodeBlock(_ input: [UInt8], _ range: Range<Int>, isLast: Bool, maximumOffset: Int, table: inout [Int32],
                                    into output: inout [UInt8]) {
        let first = input[range.lowerBound]
        if input[range].allSatisfy({ $0 == first }) {
            output += blockHeader(last: isLast, type: 1, size: range.count)
            output.append(first)
            return
        }
        var sequences: [Sequence] = []
        var literals: [UInt8] = []
        var anchor = range.lowerBound
        var position = range.lowerBound
        let end = range.upperBound
        while position + minimumMatch <= end {
            let value = read32(input, position)
            let hash = Int((value &* 2_654_435_761) >> UInt32(32 - hashLog))
            let candidate = Int(table[hash])
            table[hash] = Int32(position)
            if candidate >= 0, candidate < position, position - candidate <= maximumOffset, read32(input, candidate) == value {
                var length = minimumMatch
                while position + length < end, input[candidate + length] == input[position + length] { length += 1 }
                literals += input[anchor..<position]
                sequences.append(Sequence(literalLength: position - anchor, offset: position - candidate, matchLength: length))
                position += length
                anchor = position
            } else {
                position += 1
            }
        }
        literals += input[anchor..<end]
        var body = literalsSection(literals)
        body += sequencesSection(sequences)
        if sequences.isEmpty || body.count >= range.count {
            output += blockHeader(last: isLast, type: 0, size: range.count)
            output += input[range]
        } else {
            output += blockHeader(last: isLast, type: 2, size: body.count)
            output += body
        }
    }

    /// Raw literals section (RFC 8878 3.1.1.3.1).
    private static func literalsSection(_ literals: [UInt8]) -> [UInt8] {
        let count = literals.count
        var header: [UInt8]
        if count < 32 {
            header = [UInt8(count << 3)]
        } else if count < 4096 {
            header = [UInt8((count & 0xF) << 4 | 0b0100), UInt8(count >> 4)]
        } else {
            header = [UInt8((count & 0xF) << 4 | 0b1100), UInt8((count >> 4) & 0xFF), UInt8(count >> 12)]
        }
        return header + literals
    }

    private static func code(for value: Int, baselines: [UInt32]) -> Int {
        var code = 0
        for (index, baseline) in baselines.enumerated() where Int(baseline) <= value { code = index }
        return code
    }

    private static func sequencesSection(_ sequences: [Sequence]) -> [UInt8] {
        let count = sequences.count
        var section: [UInt8]
        if count < 128 {
            section = [UInt8(count)]
        } else if count < 0x7F00 {
            section = [UInt8((count >> 8) + 128), UInt8(count & 0xFF)]
        } else {
            section = [255] + littleEndian(UInt64(count - 0x7F00), count: 2)
        }
        guard count > 0 else { return section }
        section.append(0) // Predefined distributions for literal lengths, offsets and match lengths.

        let literalCodes = sequences.map { code(for: $0.literalLength, baselines: ZstdTables.literalLengthBaseline) }
        let matchCodes = sequences.map { code(for: $0.matchLength, baselines: ZstdTables.matchLengthBaseline) }
        let offsetValues = sequences.map { $0.offset + 3 }
        let offsetCodes = offsetValues.map { ZstdTables.highBit(UInt64($0)) }

        var writer = BitWriter()
        func extras(_ index: Int) {
            let literal = literalCodes[index]
            let match = matchCodes[index]
            writer.add(UInt64(sequences[index].literalLength - Int(ZstdTables.literalLengthBaseline[literal])),
                       Int(ZstdTables.literalLengthExtraBits[literal]))
            writer.add(UInt64(sequences[index].matchLength - Int(ZstdTables.matchLengthBaseline[match])),
                       Int(ZstdTables.matchLengthExtraBits[match]))
            writer.add(UInt64(offsetValues[index]), offsetCodes[index])
        }
        let last = count - 1
        var matchState = FSEEncoder.matchLength.initialState(matchCodes[last])
        var offsetState = FSEEncoder.offset.initialState(offsetCodes[last])
        var literalState = FSEEncoder.literalLength.initialState(literalCodes[last])
        extras(last)
        var index = last - 1
        while index >= 0 {
            FSEEncoder.offset.encode(offsetCodes[index], state: &offsetState, writer: &writer)
            FSEEncoder.matchLength.encode(matchCodes[index], state: &matchState, writer: &writer)
            FSEEncoder.literalLength.encode(literalCodes[index], state: &literalState, writer: &writer)
            extras(index)
            index -= 1
        }
        FSEEncoder.matchLength.flush(matchState, writer: &writer)
        FSEEncoder.offset.flush(offsetState, writer: &writer)
        FSEEncoder.literalLength.flush(literalState, writer: &writer)
        return section + writer.close()
    }
}

/// Forward bit writer, least significant bit first; `close` adds the end marker read by `BackwardBitReader`.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var container: UInt64 = 0
    private var count = 0

    mutating func add(_ value: UInt64, _ bits: Int) {
        guard bits > 0 else { return }
        container |= (value & ((1 << UInt64(bits)) - 1)) << UInt64(count)
        count += bits
        while count >= 8 {
            bytes.append(UInt8(truncatingIfNeeded: container))
            container >>= 8
            count -= 8
        }
    }

    mutating func close() -> [UInt8] {
        add(1, 1)
        if count > 0 { bytes.append(UInt8(truncatingIfNeeded: container)) }
        return bytes
    }
}

/// FSE encoding table for a normalized distribution (the predefined ones here), as in the reference compressor.
struct FSEEncoder {
    let tableLog: Int
    private let stateTable: [Int]
    private let deltaBits: [Int]
    private let deltaFindState: [Int]

    init(normalized: [Int16], tableLog: Int) {
        let size = 1 << tableLog
        let mask = size - 1
        let symbolCount = normalized.count
        var cumulative = [Int](repeating: 0, count: symbolCount + 1)
        var tableSymbols = [Int](repeating: 0, count: size)
        var highThreshold = size - 1
        for symbol in 0..<symbolCount {
            if normalized[symbol] == -1 {
                cumulative[symbol + 1] = cumulative[symbol] + 1
                tableSymbols[highThreshold] = symbol
                highThreshold -= 1
            } else {
                cumulative[symbol + 1] = cumulative[symbol] + Int(normalized[symbol])
            }
        }
        let step = (size >> 1) + (size >> 3) + 3
        var position = 0
        for symbol in 0..<symbolCount where normalized[symbol] > 0 {
            for _ in 0..<Int(normalized[symbol]) {
                tableSymbols[position] = symbol
                repeat { position = (position + step) & mask } while position > highThreshold
            }
        }
        var next = cumulative
        var states = [Int](repeating: 0, count: size)
        for cell in 0..<size {
            let symbol = tableSymbols[cell]
            states[next[symbol]] = size + cell
            next[symbol] += 1
        }
        var deltaBits = [Int](repeating: 0, count: symbolCount)
        var deltaFind = [Int](repeating: 0, count: symbolCount)
        var total = 0
        for symbol in 0..<symbolCount {
            let frequency = Int(normalized[symbol])
            switch frequency {
            case 0:
                deltaBits[symbol] = ((tableLog + 1) << 16) - size
            case -1, 1:
                deltaBits[symbol] = (tableLog << 16) - size
                deltaFind[symbol] = total - 1
                total += 1
            default:
                let maxBitsOut = tableLog - ZstdTables.highBit(UInt64(frequency - 1))
                let minStatePlus = frequency << maxBitsOut
                deltaBits[symbol] = (maxBitsOut << 16) - minStatePlus
                deltaFind[symbol] = total - frequency
                total += frequency
            }
        }
        self.tableLog = tableLog
        stateTable = states
        self.deltaBits = deltaBits
        deltaFindState = deltaFind
    }

    func initialState(_ symbol: Int) -> Int {
        let bits = (deltaBits[symbol] + (1 << 15)) >> 16
        let value = (bits << 16) - deltaBits[symbol]
        return stateTable[(value >> bits) + deltaFindState[symbol]]
    }

    func encode(_ symbol: Int, state: inout Int, writer: inout BitWriter) {
        let bits = (state + deltaBits[symbol]) >> 16
        writer.add(UInt64(state), bits)
        state = stateTable[(state >> bits) + deltaFindState[symbol]]
    }

    func flush(_ state: Int, writer: inout BitWriter) {
        writer.add(UInt64(state), tableLog)
    }

    static let literalLength = FSEEncoder(normalized: ZstdTables.literalLengthDefault, tableLog: ZstdTables.literalLengthDefaultLog)
    static let matchLength = FSEEncoder(normalized: ZstdTables.matchLengthDefault, tableLog: ZstdTables.matchLengthDefaultLog)
    static let offset = FSEEncoder(normalized: ZstdTables.offsetDefault, tableLog: ZstdTables.offsetDefaultLog)
}
