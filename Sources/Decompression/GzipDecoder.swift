import Foundation

/// Incremental gzip decoder (RFC 1952): members of header, raw DEFLATE body (`Inflater`) and CRC-32/ISIZE trailer,
/// any number of members, trailing zero padding tolerated.
final class GzipDecoder: StreamDecoder {
    private enum Phase {
        case header
        case body
        case trailer
    }

    private var input = InputBuffer()
    private var phase = Phase.header
    private var inflater = Inflater()
    private var crc = CRC32()
    private var memberSize: UInt32 = 0
    private var membersDecoded = 0
    private(set) var container = ContainerInfo()
    /// Longer headers (names, comments, extra fields) are refused, so a name that never ends cannot make the decoder
    /// buffer and rescan the whole object.
    static let maximumHeaderLength = 128 << 10

    func feed(_ data: Data) {
        input.append(data)
    }

    func decode(into output: inout Data, maxOutput: Int, endOfInput: Bool) throws -> DecodeState {
        let budget = max(1, maxOutput)
        var produced = 0
        while true {
            switch phase {
            case .header:
                if input.isEmpty {
                    guard endOfInput else { return .needsInput }
                    return .finished
                }
                if membersDecoded > 0, try onlyPaddingRemains(endOfInput: endOfInput) { return endOfInput ? .finished : .needsInput }
                guard let headerLength = try parseHeader() else {
                    if endOfInput { throw DecompressionError.truncated }
                    return .needsInput
                }
                container.units += 1
                if let flags = input.byte(at: 3), flags & 0x04 != 0 { container.hasExtraField = true }
                input.consume(headerLength)
                inflater = Inflater()
                crc = CRC32()
                memberSize = 0
                phase = .body
            case .body:
                guard produced < budget else { return .outputFull }
                let before = output.count
                let result = try inflater.inflate(&input, into: &output, maxOutput: budget - produced, crc: &crc)
                let made = output.count - before
                produced += made
                memberSize &+= UInt32(truncatingIfNeeded: made)
                switch result {
                case .endOfStream:
                    phase = .trailer
                case .needsInput:
                    if endOfInput { throw DecompressionError.truncated }
                    return .needsInput
                case .outputFull:
                    return .outputFull
                }
            case .trailer:
                guard input.available >= 8 else {
                    if endOfInput { throw DecompressionError.truncated }
                    return .needsInput
                }
                let storedCRC = littleEndian32(at: 0)
                let storedSize = littleEndian32(at: 4)
                guard storedCRC == crc.value else { throw DecompressionError.corrupt("gzip CRC-32 mismatch") }
                guard storedSize == memberSize else { throw DecompressionError.corrupt("gzip size mismatch") }
                input.consume(8)
                membersDecoded += 1
                phase = .header
            }
        }
    }

    private func littleEndian32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(input.byte(at: offset + index) ?? 0) << (8 * UInt32(index)) }
        return value
    }

    /// After a member: true when everything buffered is zero padding (consumed); throws for any other trailing data.
    private func onlyPaddingRemains(endOfInput: Bool) throws -> Bool {
        guard input.byte(at: 0) == 0 else {
            // Not padding: must be another member (checked by the header parser), unless it can't be one.
            if input.byte(at: 0) != 0x1F { throw DecompressionError.corrupt("unexpected data after a gzip member") }
            return false
        }
        var index = 0
        while let byte = input.byte(at: index) {
            guard byte == 0 else { throw DecompressionError.corrupt("unexpected data after a gzip member") }
            index += 1
        }
        input.consume(index)
        return true
    }

    /// Length of a complete member header at the read position; nil when more input is needed.
    private func parseHeader() throws -> Int? {
        func byte(_ index: Int) -> UInt8? { input.byte(at: index) }
        guard let id1 = byte(0) else { return nil }
        guard id1 == 0x1F else { throw DecompressionError.corrupt("not gzip data") }
        guard let id2 = byte(1) else { return nil }
        guard id2 == 0x8B else { throw DecompressionError.corrupt("not gzip data") }
        guard let method = byte(2) else { return nil }
        guard method == 8 else { throw DecompressionError.corrupt("unknown gzip compression method \(method)") }
        guard let flags = byte(3) else { return nil }
        guard flags & 0xE0 == 0 else { throw DecompressionError.corrupt("reserved gzip header flags") }
        var length = 10
        guard byte(length - 1) != nil else { return nil }
        if flags & 0x04 != 0 {
            guard let low = byte(length), let high = byte(length + 1) else { return nil }
            length += 2 + (Int(low) | Int(high) << 8)
            guard length <= Self.maximumHeaderLength else { throw DecompressionError.corrupt("gzip header longer than 128 KB") }
            guard byte(length - 1) != nil else { return nil }
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            // Zero-terminated name or comment.
            while true {
                guard length <= Self.maximumHeaderLength else { throw DecompressionError.corrupt("gzip header longer than 128 KB") }
                guard let value = byte(length) else { return nil }
                length += 1
                if value == 0 { break }
            }
        }
        if flags & 0x02 != 0 {
            guard let low = byte(length), let high = byte(length + 1) else { return nil }
            var headerCRC = CRC32()
            headerCRC.update((0..<length).map { byte($0) ?? 0 })
            guard UInt16(low) | UInt16(high) << 8 == UInt16(truncatingIfNeeded: headerCRC.value) else {
                throw DecompressionError.corrupt("gzip header checksum mismatch")
            }
            length += 2
        }
        return length
    }
}
