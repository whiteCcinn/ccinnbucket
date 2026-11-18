@testable import Decompression
import Foundation
import Testing

@Suite("Decoding fixtures made by the gzip and zstd CLIs")
struct FixtureDecodingTests {
    static let entries = Fixtures.manifest

    @Test("every fixture decodes to the expected bytes for any chunking and output limit", arguments: entries.map(\.file))
    func decodes(file: String) throws {
        let entry = Self.entries.first { $0.file == file }!
        let input = Fixtures.data(file)
        let chunks = input.count <= 70_000 ? [1, 7, 4096, Int.max] : [7, 4096, Int.max]
        for chunk in chunks {
            for maxOutput in [1_000, 65_536, Int.max] {
                let output = try Decode.all(input, format: Fixtures.format(entry), chunk: chunk, maxOutput: maxOutput)
                #expect(output.count == entry.size, "\(file) chunk \(chunk) max \(maxOutput)")
                #expect(Decode.sha256(output) == entry.sha256, "\(file) chunk \(chunk) max \(maxOutput)")
            }
        }
    }

    @Test("format sniffing agrees with the fixtures")
    func sniffing() {
        for entry in Self.entries {
            #expect(CompressionFormat.sniff(Fixtures.data(entry.file)) == Fixtures.format(entry), "\(entry.file)")
        }
    }
}
