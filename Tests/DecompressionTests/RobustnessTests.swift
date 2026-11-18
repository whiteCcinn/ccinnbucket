@testable import Decompression
import Foundation
import Testing

@Suite("Malformed input never traps")
struct RobustnessTests {
    static let entries = Fixtures.manifest

    @Test("truncated input throws, or finishes with a prefix of the content (frame or member boundary)", arguments: entries.map(\.file))
    func truncation(file: String) throws {
        let entry = Self.entries.first { $0.file == file }!
        let input = Fixtures.data(file)
        let expected = try Decode.all(input, format: Fixtures.format(entry))
        var cuts = Set([0, 1, 2, 3, 4, 5, 6, 9, 10, 12, 18, input.count - 1, input.count - 4, input.count - 8, input.count - 9])
        var rng = SeededGenerator(seed: UInt64(truncatingIfNeeded: file.hashValue & 0x7FFF_FFFF) | 1)
        for _ in 0..<40 { cuts.insert(Int.random(in: 0..<input.count, using: &rng)) }
        for cut in cuts where cut >= 0 && cut < input.count {
            do {
                let output = try Decode.all(input.prefix(cut), format: Fixtures.format(entry), chunk: 4096, maxOutput: 1 << 20)
                #expect(expected.starts(with: output), "\(file) cut at \(cut) finished with content that is not a prefix")
            } catch is DecompressionError {
                // Expected for almost every cut.
            }
        }
    }

    @Test("flipped bytes throw or decode to something, without trapping or looping", arguments: entries.map(\.file))
    func corruption(file: String) throws {
        let entry = Self.entries.first { $0.file == file }!
        let original = [UInt8](Fixtures.data(file))
        var rng = SeededGenerator(seed: 0xC0FFEE ^ UInt64(original.count))
        // DECOMPRESSION_FUZZ_ITERATIONS raises the count for a deeper local run.
        let iterations = ProcessInfo.processInfo.environment["DECOMPRESSION_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 60
        for _ in 0..<iterations {
            var mutated = original
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let index = Int.random(in: 0..<mutated.count, using: &rng)
                mutated[index] ^= UInt8.random(in: 1...255, using: &rng)
            }
            do {
                _ = try Decode.all(Data(mutated), format: Fixtures.format(entry), chunk: 4096, maxOutput: 1 << 20)
            } catch is DecompressionError {
            }
        }
    }

    @Test("flips in headers and table descriptions (the first 600 bytes) never trap", arguments: entries.map(\.file))
    func headerCorruption(file: String) throws {
        let entry = Self.entries.first { $0.file == file }!
        let original = [UInt8](Fixtures.data(file))
        var rng = SeededGenerator(seed: 0xBADC0DE ^ UInt64(original.count))
        let iterations = ProcessInfo.processInfo.environment["DECOMPRESSION_FUZZ_ITERATIONS"].flatMap(Int.init) ?? 60
        for _ in 0..<iterations {
            var mutated = original
            for _ in 0..<Int.random(in: 1...2, using: &rng) {
                let index = Int.random(in: 0..<min(mutated.count, 600), using: &rng)
                mutated[index] ^= UInt8(1) << UInt8.random(in: 0...7, using: &rng)
            }
            do {
                _ = try Decode.all(Data(mutated), format: Fixtures.format(entry), chunk: 997, maxOutput: 1 << 20)
            } catch is DecompressionError {
            }
        }
    }

    @Test("random garbage and short headers are rejected")
    func garbage() throws {
        var rng = SeededGenerator(seed: 42)
        for format in CompressionFormat.allCases {
            for length in [0, 1, 3, 4, 5, 13, 64, 1000] {
                var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
                if length >= 4 {
                    // Correct magic, random rest: exercises header and block parsing.
                    let magic: [UInt8] = format == .gzip ? [0x1F, 0x8B, 0x08] : [0x28, 0xB5, 0x2F, 0xFD]
                    for (index, byte) in magic.enumerated() { bytes[index] = byte }
                }
                do {
                    _ = try Decode.all(Data(bytes), format: format)
                    #expect(length == 0, "\(format) accepted \(length) random bytes")
                } catch is DecompressionError {
                }
            }
        }
    }

    @Test("an empty input is an empty stream")
    func emptyInput() throws {
        for format in CompressionFormat.allCases {
            #expect(try Decode.all(Data(), format: format).isEmpty)
        }
    }
}
