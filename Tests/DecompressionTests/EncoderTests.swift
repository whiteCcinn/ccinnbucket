@testable import Decompression
import Foundation
import Testing

@Suite("Encoders round-trip and interoperate with the CLIs")
struct EncoderTests {
    static func inputs() throws -> [(String, Data)] {
        var rng = SeededGenerator(seed: 7)
        let text = try Fixtures.plaintext("text-l3.zst")
        let random = Data((0..<200_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
        var mixed = Data()
        while mixed.count < 1_500_000 {
            mixed.append(text.prefix(Int.random(in: 1_000...40_000, using: &rng)))
            mixed.append(Data((0..<Int.random(in: 0...3_000, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
        }
        return [
            ("empty", Data()), ("one byte", Data([0x41])), ("hello", Data("hello, world\n".utf8)), ("text", text),
            ("random", random), ("runs", Data(repeating: 0x61, count: 300_000) + Data(repeating: 0x62, count: 1)),
            ("json", try Fixtures.plaintext("data-l19.zst")), ("mixed 1.5 MiB", mixed),
        ]
    }

    @Test("zstd: round trip through our decoder; compresses text; the zstd CLI accepts the output")
    func zstd() throws {
        let cli = ExternalTool.find("zstd")
        for (name, input) in try Self.inputs() {
            let compressed = try ZstdEncoder.compress(input)
            #expect(CompressionFormat.sniff(compressed) == .zstd, "\(name)")
            #expect(try Decode.all(compressed, format: .zstd, chunk: 5_000, maxOutput: 70_000) == input, "\(name)")
            if name == "text" || name == "json" || name == "runs" {
                #expect(compressed.count < input.count / 2, "\(name): \(compressed.count) of \(input.count)")
            }
            if name == "random" { #expect(compressed.count < input.count + 1_000, "random stays near raw size") }
            if let cli {
                let viaCLI = try ExternalTool.run(cli, ["-d", "-q", "-c"], input: compressed)
                #expect(viaCLI == input, "\(name): zstd -d rejected or changed our output")
            }
        }
    }

    @Test("gzip: round trip through our decoder and through gzip -d")
    func gzip() throws {
        let cli = ExternalTool.find("gzip")
        for (name, input) in try Self.inputs() {
            let compressed = try GzipEncoder.compress(input)
            #expect(CompressionFormat.sniff(compressed) == .gzip, "\(name)")
            #expect(try Decode.all(compressed, format: .gzip, chunk: 3_000) == input, "\(name)")
            if let cli {
                #expect(try ExternalTool.run(cli, ["-d", "-c"], input: compressed) == input, "\(name): gzip -d")
            }
        }
    }

    @Test("format.compress uses the matching encoder")
    func dispatch() throws {
        let input = Data("same bytes, two formats\n".utf8)
        for format in CompressionFormat.allCases {
            #expect(try Decode.all(try format.compress(input), format: format) == input)
        }
    }
}
