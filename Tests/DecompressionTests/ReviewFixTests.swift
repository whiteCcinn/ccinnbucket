import Decompression
import Foundation
import Testing

@Suite("Review fixes: header limits and container structure")
struct ReviewFixTests {
    private static func gzipHeader(flags: UInt8) -> Data { Data([0x1F, 0x8B, 0x08, flags, 0, 0, 0, 0, 0, 0xFF]) }

    @Test("a gzip name that never ends is refused instead of buffering the whole object")
    func unterminatedName() throws {
        let decoder = CompressionFormat.gzip.makeDecoder()
        decoder.feed(Self.gzipHeader(flags: 0x08) + Data(repeating: 0x41, count: 300_000))
        var output = Data()
        #expect(throws: DecompressionError.self) { _ = try decoder.decode(into: &output, maxOutput: 1 << 20, endOfInput: false) }
    }

    @Test("container structure: gzip extra field and members, zstd frames and skippable frames")
    func containerInfo() throws {
        // A gzip member with an extra field (as BGZF writes), compressed by our encoder for the body.
        let plain = Data("hello container\n".utf8)
        let member = try CompressionFormat.gzip.compress(plain)
        var withExtra = Data(member.prefix(10))
        withExtra[3] |= 0x04
        withExtra += Data([4, 0, 0x42, 0x43, 0, 0]) + member.dropFirst(10)
        let gzip = CompressionFormat.gzip.makeDecoder()
        gzip.feed(withExtra + member)
        var output = Data()
        #expect(try gzip.decode(into: &output, maxOutput: 1 << 20, endOfInput: true) == .finished)
        #expect(output == plain + plain)
        #expect(gzip.container == ContainerInfo(units: 2, skippableFrames: 0, hasExtraField: true))

        let frame = try CompressionFormat.zstd.compress(plain)
        let skippable = Data([0x50, 0x2A, 0x4D, 0x18, 3, 0, 0, 0, 1, 2, 3])
        let zstd = CompressionFormat.zstd.makeDecoder()
        zstd.feed(frame + skippable + frame)
        output = Data()
        #expect(try zstd.decode(into: &output, maxOutput: 1 << 20, endOfInput: true) == .finished)
        #expect(zstd.container == ContainerInfo(units: 2, skippableFrames: 1, hasExtraField: false))
    }
}
