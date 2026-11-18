@testable import Decompression
import Foundation
import Testing

@Suite("Zstandard frame rules")
struct ZstdFrameTests {
    private let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    @Test("a frame that needs a dictionary is unsupported")
    func dictionary() {
        // Descriptor: Dictionary_ID_flag = 1 (one byte), single segment, FCS 1 byte; dictionary id 7; FCS 0; empty raw last block.
        let frame = Data(magic + [0b0010_0001, 0x07, 0x00, 0x01, 0x00, 0x00])
        #expect(throws: DecompressionError.unsupported("a zstd dictionary is required (id 7)")) {
            _ = try Decode.all(frame, format: .zstd)
        }
    }

    @Test("windows above 128 MiB are unsupported; reserved bits are corrupt")
    func windowAndReserved() {
        // Window_Descriptor exponent 18 → 2^28 bytes.
        let huge = Data(magic + [0x00, 18 << 3, 0x01, 0x00, 0x00])
        #expect(throws: DecompressionError.self) { _ = try Decode.all(huge, format: .zstd) }
        do {
            _ = try Decode.all(huge, format: .zstd)
        } catch let error as DecompressionError {
            if case .unsupported = error {} else { Issue.record("expected unsupported, got \(error)") }
        } catch {
            Issue.record("unexpected \(error)")
        }
        let reserved = Data(magic + [0b0010_1000, 0x00, 0x01, 0x00, 0x00])
        #expect(throws: DecompressionError.self) { _ = try Decode.all(reserved, format: .zstd) }
    }

    @Test("content size and checksum mismatches are corrupt")
    func mismatches() throws {
        var frame = [UInt8](Fixtures.data("small.zst"))
        // Last 4 bytes are the content checksum.
        frame[frame.count - 1] ^= 0xFF
        #expect(throws: DecompressionError.self) { _ = try Decode.all(Data(frame), format: .zstd) }
        // Single segment, FCS (1 byte) says 5 but one raw block of 3 bytes follows.
        let wrongSize = Data(magic + [0b0010_0000, 0x05, 0x19, 0x00, 0x00, 0x61, 0x62, 0x63])
        #expect(throws: DecompressionError.self) { _ = try Decode.all(wrongSize, format: .zstd) }
        // The same frame with FCS 3 decodes.
        let rightSize = Data(magic + [0b0010_0000, 0x03, 0x19, 0x00, 0x00, 0x61, 0x62, 0x63])
        #expect(try Decode.all(rightSize, format: .zstd) == Data("abc".utf8))
    }

    @Test("skippable frames alone decode to nothing; unknown magic is corrupt")
    func skippable() throws {
        let skip = Data([0x50, 0x2A, 0x4D, 0x18, 0x03, 0x00, 0x00, 0x00, 1, 2, 3])
        #expect(try Decode.all(skip, format: .zstd).isEmpty)
        #expect(throws: DecompressionError.self) { _ = try Decode.all(Data([1, 2, 3, 4, 5, 6, 7, 8]), format: .zstd) }
    }

    @Test("history stays bounded while decoding a long stream")
    func boundedHistory() throws {
        // 40 frames' worth of runs: RLE blocks keep the input tiny while the output is large.
        let decoder = ZstdDecoder()
        let input = Fixtures.data("runs.zst")
        var produced = 0
        for _ in 0..<40 {
            decoder.feed(input)
            var output = Data()
            while try decoder.decode(into: &output, maxOutput: 1 << 16, endOfInput: false) == .outputFull {
                produced += output.count
                output.removeAll(keepingCapacity: true)
            }
            produced += output.count
        }
        #expect(produced == 40 * 303_000)
        #expect(decoder.retainedHistoryBytes <= 1 << 20)
    }
}
