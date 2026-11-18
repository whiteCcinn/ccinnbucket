import Foundation

/// Incremental Zstandard decoder (RFC 8878) without dictionary support. Whole blocks (≤ 128 KiB) are decoded once
/// they are buffered; only the frame's window of history is kept, so memory stays bounded for any stream length.
final class ZstdDecoder: StreamDecoder {
    /// Larger windows are refused rather than allocated.
    static let maximumWindowSize = 128 << 20
    private static let frameMagic: UInt32 = 0xFD2F_B528

    private struct Frame {
        var windowSize: Int
        var contentSize: UInt64?
        var hasChecksum: Bool
        var decodedSize: UInt64 = 0
        var hasher = XXH64()
        var repeatOffsets = [1, 4, 8]
        var huffman: HuffmanTable?
        var literalLengthTable: FSETable?
        var offsetTable: FSETable?
        var matchLengthTable: FSETable?

        var blockMaximumSize: Int { min(windowSize, ZstdTables.blockMaximumSize) }
    }

    private enum Phase {
        case frameStart
        case blocks
        case checksum
        case skippable(remaining: Int)
    }

    private var input = InputBuffer()
    private var phase = Phase.frameStart
    private(set) var container = ContainerInfo()
    private var frame: Frame?
    /// The current frame's most recent output (at least its window once that much was decoded).
    private var history: [UInt8] = []

    /// Bytes of history currently held (for tests: memory stays bounded).
    var retainedHistoryBytes: Int { history.count }

    func feed(_ data: Data) {
        input.append(data)
    }

    func decode(into output: inout Data, maxOutput: Int, endOfInput: Bool) throws -> DecodeState {
        let budget = max(1, maxOutput)
        var produced = 0
        func needInput() throws -> DecodeState {
            if endOfInput { throw DecompressionError.truncated }
            return .needsInput
        }
        while true {
            switch phase {
            case .frameStart:
                if input.isEmpty { return endOfInput ? .finished : .needsInput }
                guard input.available >= 4 else { return try needInput() }
                let magic = littleEndian(at: 0, count: 4)
                if magic == UInt64(Self.frameMagic) {
                    guard let header = try parseFrameHeader() else { return try needInput() }
                    input.consume(header.length)
                    container.units += 1
                    frame = header.frame
                    history.removeAll(keepingCapacity: false)
                    phase = .blocks
                } else if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
                    guard input.available >= 8 else { return try needInput() }
                    let size = Int(littleEndian(at: 4, count: 4))
                    input.consume(8)
                    container.skippableFrames += 1
                    phase = .skippable(remaining: size)
                } else {
                    throw DecompressionError.corrupt("unknown frame magic")
                }
            case let .skippable(remaining):
                let skip = min(remaining, input.available)
                input.consume(skip)
                if skip < remaining {
                    phase = .skippable(remaining: remaining - skip)
                    return try needInput()
                }
                phase = .frameStart
            case .blocks:
                guard produced < budget else { return .outputFull }
                guard var current = frame else { throw DecompressionError.corrupt("block outside a frame") }
                guard input.available >= 3 else { return try needInput() }
                let header = Int(littleEndian(at: 0, count: 3))
                let isLast = header & 1 == 1
                let type = (header >> 1) & 3
                let size = header >> 3
                guard size <= current.blockMaximumSize else { throw DecompressionError.corrupt("block larger than the maximum") }
                let start = history.count
                switch type {
                case 0:
                    guard input.available >= 3 + size else { return try needInput() }
                    history.append(contentsOf: input.bytes[(input.start + 3)..<(input.start + 3 + size)])
                    input.consume(3 + size)
                case 1:
                    guard input.available >= 4, let byte = input.byte(at: 3) else { return try needInput() }
                    history.append(contentsOf: repeatElement(byte, count: size))
                    input.consume(4)
                case 2:
                    guard input.available >= 3 + size else { return try needInput() }
                    let block = Array(input.bytes[(input.start + 3)..<(input.start + 3 + size)])
                    input.consume(3 + size)
                    try decodeCompressedBlock(block, frame: &current)
                default:
                    throw DecompressionError.corrupt("reserved block type")
                }
                let fresh = history.count - start
                if fresh > 0 {
                    output.append(contentsOf: history[start...])
                    if current.hasChecksum { current.hasher.update(history[start...]) }
                    current.decodedSize &+= UInt64(fresh)
                    produced += fresh
                }
                if let contentSize = current.contentSize, current.decodedSize > contentSize {
                    throw DecompressionError.corrupt("frame longer than its declared content size")
                }
                trimHistory(window: current.windowSize)
                frame = current
                if isLast {
                    if current.hasChecksum {
                        phase = .checksum
                    } else {
                        try finishFrame()
                    }
                }
            case .checksum:
                guard input.available >= 4 else { return try needInput() }
                let stored = UInt32(littleEndian(at: 0, count: 4))
                input.consume(4)
                guard let current = frame, stored == UInt32(truncatingIfNeeded: current.hasher.digest()) else {
                    throw DecompressionError.corrupt("content checksum mismatch")
                }
                try finishFrame()
            }
        }
    }

    private func finishFrame() throws {
        if let current = frame, let contentSize = current.contentSize, contentSize != current.decodedSize {
            throw DecompressionError.corrupt("frame size differs from its declared content size")
        }
        frame = nil
        history.removeAll(keepingCapacity: false)
        phase = .frameStart
    }

    /// Keeps at least the window; trims in steps so the copying stays proportional to the output.
    private func trimHistory(window: Int) {
        let slack = max(1 << 20, window / 4)
        if history.count > window + slack { history.removeFirst(history.count - window) }
    }

    private func littleEndian(at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(input.byte(at: offset + index) ?? 0) << UInt64(8 * index) }
        return value
    }

    // MARK: Frame header

    private func parseFrameHeader() throws -> (frame: Frame, length: Int)? {
        guard let descriptor = input.byte(at: 4) else { return nil }
        let contentSizeFlag = Int(descriptor >> 6)
        let singleSegment = descriptor & 0x20 != 0
        guard descriptor & 0x08 == 0 else { throw DecompressionError.corrupt("reserved frame header bit set") }
        let hasChecksum = descriptor & 0x04 != 0
        let dictionaryIDSize = [0, 1, 2, 4][Int(descriptor & 3)]
        let contentSizeSize = [singleSegment ? 1 : 0, 2, 4, 8][contentSizeFlag]
        var offset = 5
        let length = offset + (singleSegment ? 0 : 1) + dictionaryIDSize + contentSizeSize
        guard input.available >= length else { return nil }

        var windowSize = 0
        if !singleSegment {
            let windowDescriptor = Int(input.byte(at: offset) ?? 0)
            offset += 1
            let windowLog = 10 + (windowDescriptor >> 3)
            let base = 1 << windowLog
            windowSize = base + (base / 8) * (windowDescriptor & 7)
        }
        if dictionaryIDSize > 0 {
            let dictionaryID = littleEndian(at: offset, count: dictionaryIDSize)
            offset += dictionaryIDSize
            if dictionaryID != 0 { throw DecompressionError.unsupported("a zstd dictionary is required (id \(dictionaryID))") }
        }
        var contentSize: UInt64?
        if contentSizeSize > 0 {
            var value = littleEndian(at: offset, count: contentSizeSize)
            if contentSizeSize == 2 { value += 256 }
            contentSize = value
        }
        if singleSegment {
            guard let contentSize, contentSize <= UInt64(Self.maximumWindowSize) else {
                throw DecompressionError.unsupported("a single-segment zstd frame larger than 128 MiB")
            }
            windowSize = Int(contentSize)
        }
        guard windowSize <= Self.maximumWindowSize else {
            throw DecompressionError.unsupported("a zstd window of \(windowSize >> 20) MiB (at most 128 MiB)")
        }
        return (Frame(windowSize: max(windowSize, 1), contentSize: contentSize, hasChecksum: hasChecksum), length)
    }

    // MARK: Compressed blocks

    private func decodeCompressedBlock(_ block: [UInt8], frame: inout Frame) throws {
        let (literals, literalsSize) = try decodeLiterals(block, frame: &frame)
        try decodeSequences(block, from: literalsSize, literals: literals, frame: &frame)
    }

    private func decodeLiterals(_ block: [UInt8], frame: inout Frame) throws -> ([UInt8], Int) {
        guard let first = block.first else { throw DecompressionError.corrupt("empty compressed block") }
        let type = Int(first & 3)
        let sizeFormat = Int(first >> 2) & 3
        func byte(_ index: Int) throws -> Int {
            guard index < block.count else { throw DecompressionError.corrupt("literals header overruns the block") }
            return Int(block[index])
        }
        let maximum = frame.blockMaximumSize
        if type < 2 {
            var regenerated: Int
            var headerSize: Int
            switch sizeFormat {
            case 1:
                regenerated = (Int(first) >> 4) + (try byte(1) << 4)
                headerSize = 2
            case 3:
                regenerated = (Int(first) >> 4) + (try byte(1) << 4) + (try byte(2) << 12)
                headerSize = 3
            default:
                regenerated = Int(first) >> 3
                headerSize = 1
            }
            guard regenerated <= maximum else { throw DecompressionError.corrupt("too many literals") }
            if type == 0 {
                guard headerSize + regenerated <= block.count else { throw DecompressionError.corrupt("raw literals overrun the block") }
                return (Array(block[headerSize..<(headerSize + regenerated)]), headerSize + regenerated)
            }
            let value = UInt8(try byte(headerSize))
            return ([UInt8](repeating: value, count: regenerated), headerSize + 1)
        }

        let headerSize = [3, 3, 4, 5][sizeFormat]
        let sizeBits = [10, 10, 14, 18][sizeFormat]
        var combined = 0
        for index in 0..<headerSize { combined |= try byte(index) << (8 * index) }
        let mask = (1 << sizeBits) - 1
        let regenerated = (combined >> 4) & mask
        let compressedSize = (combined >> (4 + sizeBits)) & mask
        guard regenerated <= maximum else { throw DecompressionError.corrupt("too many literals") }
        guard headerSize + compressedSize <= block.count else { throw DecompressionError.corrupt("compressed literals overrun the block") }
        var body = Array(block[headerSize..<(headerSize + compressedSize)])
        if type == 2 {
            let (table, used) = try HuffmanTable.read(body)
            frame.huffman = table
            body = Array(body[used...])
        }
        guard let table = frame.huffman else { throw DecompressionError.corrupt("treeless literals without a previous Huffman table") }
        var literals: [UInt8] = []
        literals.reserveCapacity(regenerated)
        if sizeFormat == 0 {
            try table.decodeStream(body, into: &literals, limit: regenerated)
        } else {
            guard body.count >= 6 else { throw DecompressionError.corrupt("missing literal stream jump table") }
            let sizes = (0..<3).map { Int(body[2 * $0]) | Int(body[2 * $0 + 1]) << 8 }
            let total = sizes.reduce(0, +)
            guard 6 + total < body.count else { throw DecompressionError.corrupt("literal streams overrun their section") }
            var start = 6
            for size in sizes + [body.count - 6 - total] {
                guard size > 0 else { throw DecompressionError.corrupt("empty literal stream") }
                try table.decodeStream(Array(body[start..<(start + size)]), into: &literals, limit: regenerated)
                start += size
            }
        }
        guard literals.count == regenerated else { throw DecompressionError.corrupt("literal count mismatch") }
        return (literals, headerSize + compressedSize)
    }

    private func decodeSequences(_ block: [UInt8], from start: Int, literals: [UInt8], frame: inout Frame) throws {
        var position = start
        func byte() throws -> Int {
            guard position < block.count else { throw DecompressionError.corrupt("sequences header overruns the block") }
            defer { position += 1 }
            return Int(block[position])
        }
        let first = try byte()
        var count = first
        if first == 255 {
            count = try byte() + (try byte() << 8) + 0x7F00
        } else if first >= 128 {
            count = ((first - 128) << 8) + (try byte())
        }
        let blockStart = history.count
        let limit = frame.blockMaximumSize
        if count == 0 {
            guard position == block.count else { throw DecompressionError.corrupt("data after an empty sequences section") }
            history.append(contentsOf: literals)
            return
        }
        let modes = try byte()
        guard modes & 3 == 0 else { throw DecompressionError.corrupt("reserved sequence mode bits set") }
        func table(mode: Int, defaultTable: FSETable, previous: FSETable?, maxLog: Int, maxSymbol: Int) throws -> FSETable {
            switch mode {
            case 0:
                return defaultTable
            case 1:
                let symbol = try byte()
                guard symbol <= maxSymbol else { throw DecompressionError.corrupt("RLE sequence symbol out of range") }
                return FSETable(rle: UInt8(symbol))
            case 2:
                guard position < block.count else { throw DecompressionError.corrupt("missing FSE table") }
                let (table, used) = try FSETable.read(Array(block[position...]), maxAccuracyLog: maxLog, maxSymbol: maxSymbol)
                position += used
                return table
            default:
                guard let previous else { throw DecompressionError.corrupt("repeat mode without a previous table") }
                return previous
            }
        }
        let literalLengths = try table(mode: modes >> 6, defaultTable: .literalLengthDefault, previous: frame.literalLengthTable,
                                       maxLog: ZstdTables.literalLengthMaxLog, maxSymbol: ZstdTables.maxLiteralLengthCode)
        let offsets = try table(mode: (modes >> 4) & 3, defaultTable: .offsetDefault, previous: frame.offsetTable,
                                maxLog: ZstdTables.offsetMaxLog, maxSymbol: ZstdTables.maxOffsetCode)
        let matchLengths = try table(mode: (modes >> 2) & 3, defaultTable: .matchLengthDefault, previous: frame.matchLengthTable,
                                     maxLog: ZstdTables.matchLengthMaxLog, maxSymbol: ZstdTables.maxMatchLengthCode)
        frame.literalLengthTable = literalLengths
        frame.offsetTable = offsets
        frame.matchLengthTable = matchLengths
        guard position < block.count else { throw DecompressionError.corrupt("missing sequences bitstream") }

        var reader = try BackwardBitReader(Array(block[position...]))
        var literalState = Int(reader.read(literalLengths.accuracyLog))
        var offsetState = Int(reader.read(offsets.accuracyLog))
        var matchState = Int(reader.read(matchLengths.accuracyLog))
        var literalPosition = 0
        var repeats = frame.repeatOffsets
        let window = frame.windowSize

        for index in 0..<count {
            let offsetCode = Int(offsets.symbols[offsetState])
            let literalCode = Int(literalLengths.symbols[literalState])
            let matchCode = Int(matchLengths.symbols[matchState])
            guard literalCode <= ZstdTables.maxLiteralLengthCode, matchCode <= ZstdTables.maxMatchLengthCode,
                  offsetCode <= ZstdTables.maxOffsetCode else { throw DecompressionError.corrupt("sequence code out of range") }
            let offsetValue = (1 << offsetCode) + Int(reader.read(offsetCode))
            let matchLength = Int(ZstdTables.matchLengthBaseline[matchCode]) + Int(reader.read(Int(ZstdTables.matchLengthExtraBits[matchCode])))
            let literalLength = Int(ZstdTables.literalLengthBaseline[literalCode])
                + Int(reader.read(Int(ZstdTables.literalLengthExtraBits[literalCode])))
            if index < count - 1 {
                literalState = Int(literalLengths.baselines[literalState]) + Int(reader.read(Int(literalLengths.bitCounts[literalState])))
                matchState = Int(matchLengths.baselines[matchState]) + Int(reader.read(Int(matchLengths.bitCounts[matchState])))
                offsetState = Int(offsets.baselines[offsetState]) + Int(reader.read(Int(offsets.bitCounts[offsetState])))
            }

            // Repeat offsets (RFC 8878 3.1.2.5).
            var offset: Int
            if offsetValue > 3 {
                offset = offsetValue - 3
                repeats = [offset, repeats[0], repeats[1]]
            } else {
                var repeatIndex = offsetValue - 1
                if literalLength == 0 { repeatIndex += 1 }
                if repeatIndex == 0 {
                    offset = repeats[0]
                } else {
                    offset = repeatIndex < 3 ? repeats[repeatIndex] : repeats[0] - 1
                    if repeatIndex > 1 { repeats[2] = repeats[1] }
                    repeats[1] = repeats[0]
                    repeats[0] = offset
                }
            }

            guard literalPosition + literalLength <= literals.count else { throw DecompressionError.corrupt("sequence uses more literals than decoded") }
            guard history.count - blockStart + literalLength + matchLength <= limit else {
                throw DecompressionError.corrupt("block decodes to more than its maximum size")
            }
            history.append(contentsOf: literals[literalPosition..<(literalPosition + literalLength)])
            literalPosition += literalLength
            guard offset > 0, offset <= history.count, offset <= window else { throw DecompressionError.corrupt("match offset out of range") }
            // Byte by byte: overlapping matches repeat recent output, and no slice of `history` stays alive while appending.
            let from = history.count - offset
            for step in 0..<matchLength { history.append(history[from + step]) }
        }
        guard reader.offset == 0 else { throw DecompressionError.corrupt("sequences bitstream not consumed exactly") }
        guard history.count - blockStart + literals.count - literalPosition <= limit else {
            throw DecompressionError.corrupt("block decodes to more than its maximum size")
        }
        history.append(contentsOf: literals[literalPosition...])
        frame.repeatOffsets = repeats
    }
}
