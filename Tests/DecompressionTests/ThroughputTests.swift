@testable import Decompression
import Foundation
import Testing

@Suite("Throughput sanity (no quadratic behaviour)")
struct ThroughputTests {
    /// About 30 MiB of log-like text.
    static func largeText() throws -> Data {
        let base = try Fixtures.plaintext("text-l3.zst")
        var data = Data(capacity: 31 << 20)
        var counter = 0
        while data.count < 30 << 20 {
            data.append(Data("chunk \(counter)\n".utf8))
            data.append(base)
            counter += 1
        }
        return data
    }

    @Test("30 MiB of zstd and gzip decode in bounded time")
    func throughput() throws {
        let text = try Self.largeText()
        var compressed: [(CompressionFormat, Data)] = [(.gzip, try GzipEncoder.compress(text))]
        if let cli = ExternalTool.find("zstd"), let viaCLI = try ExternalTool.run(cli, ["-3", "-q", "-c"], input: text) {
            compressed.append((.zstd, viaCLI))
        } else {
            compressed.append((.zstd, try ZstdEncoder.compress(text)))
        }
        for (format, input) in compressed {
            let start = Date()
            let output = try Decode.all(input, format: format, chunk: 1 << 20, maxOutput: 4 << 20)
            let seconds = Date().timeIntervalSince(start)
            #expect(output.count == text.count)
            #expect(output == text)
            let rate = Double(output.count) / max(seconds, 0.001) / 1_048_576
            print("\(format) decoded \(output.count >> 20) MiB in \(String(format: "%.2f", seconds)) s (\(String(format: "%.1f", rate)) MiB/s)")
            #expect(seconds < 60)
        }
    }
}
