import Decompression
import Foundation
import Testing

@Suite("Compression formats")
struct FormatTests {
    @Test("formats from extensions and magic bytes")
    func detection() {
        #expect(CompressionFormat.fromExtension("GZ") == .gzip)
        #expect(CompressionFormat.fromExtension("tgz") == .gzip)
        #expect(CompressionFormat.fromExtension("zst") == .zstd)
        #expect(CompressionFormat.fromExtension("zstd") == .zstd)
        #expect(CompressionFormat.fromExtension("json") == nil)
        #expect(CompressionFormat.sniff(Data([0x1F, 0x8B, 0x08])) == .gzip)
        #expect(CompressionFormat.sniff(Data([0x28, 0xB5, 0x2F, 0xFD, 0x00])) == .zstd)
        #expect(CompressionFormat.sniff(Data([0x28, 0xB5])) == nil)
        #expect(CompressionFormat.sniff(Data()) == nil)
    }
}
