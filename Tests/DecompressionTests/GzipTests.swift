import Compression
@testable import Decompression
import Foundation
import Testing

@Suite("gzip members")
struct GzipTests {
    private static func rawDeflate(_ data: Data) -> Data {
        let input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: input.count + input.count / 8 + 1024)
        let count = compression_encode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_ZLIB)
        return Data(output.prefix(count))
    }

    private static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    /// A member with every optional header field.
    private static func member(_ content: Data, flags: UInt8 = 0b0001_1110, corruptHeaderCRC: Bool = false) -> Data {
        var header: [UInt8] = [0x1F, 0x8B, 0x08, flags, 0, 0, 0, 0, 0, 3]
        if flags & 0x04 != 0 { header += [3, 0, 0xAA, 0xBB, 0xCC] }
        if flags & 0x08 != 0 { header += Array("name.txt".utf8) + [0] }
        if flags & 0x10 != 0 { header += Array("a comment".utf8) + [0] }
        if flags & 0x02 != 0 {
            let crc = CRC32.checksum(Data(header)) ^ (corruptHeaderCRC ? 1 : 0)
            header += [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
        }
        return Data(header) + rawDeflate(content) + Data(le32(CRC32.checksum(content)) + le32(UInt32(truncatingIfNeeded: content.count)))
    }

    private let content = Data((0..<20_000).map { "row \($0)\n" }.joined().utf8)

    @Test("FEXTRA, FNAME, FCOMMENT and FHCRC headers decode")
    func optionalFields() throws {
        #expect(try Decode.all(Self.member(content), format: .gzip, chunk: 3) == content)
        #expect(throws: DecompressionError.self) { _ = try Decode.all(Self.member(content, corruptHeaderCRC: true), format: .gzip) }
    }

    @Test("reserved flags, wrong method, CRC and ISIZE mismatches are corrupt")
    func corruptMembers() {
        #expect(throws: DecompressionError.self) { _ = try Decode.all(Self.member(content, flags: 0x20), format: .gzip) }
        var method = [UInt8](Self.member(content, flags: 0))
        method[2] = 7
        #expect(throws: DecompressionError.self) { _ = try Decode.all(Data(method), format: .gzip) }
        var crc = [UInt8](Self.member(content, flags: 0))
        crc[crc.count - 8] ^= 1
        #expect(throws: DecompressionError.self) { _ = try Decode.all(Data(crc), format: .gzip) }
        var size = [UInt8](Self.member(content, flags: 0))
        size[size.count - 1] ^= 1
        #expect(throws: DecompressionError.self) { _ = try Decode.all(Data(size), format: .gzip) }
    }

    @Test("members concatenate; trailing zero padding is ignored, other trailing data is not")
    func membersAndPadding() throws {
        let two = Self.member(content, flags: 0) + Self.member(Data("tail".utf8), flags: 0x08)
        #expect(try Decode.all(two, format: .gzip, chunk: 1000) == content + Data("tail".utf8))
        #expect(try Decode.all(two + Data(repeating: 0, count: 512), format: .gzip) == content + Data("tail".utf8))
        #expect(throws: DecompressionError.self) { _ = try Decode.all(two + Data("junk".utf8), format: .gzip) }
    }

    @Test("stored, fixed and dynamic deflate blocks from the gzip CLI and Compression decode")
    func blockTypes() throws {
        let random = Data((0..<70_000).map { _ in UInt8.random(in: 0...255) })
        #expect(try Decode.all(Self.member(random, flags: 0), format: .gzip, chunk: 777) == random)
        #expect(try Decode.all(Self.member(Data("a".utf8), flags: 0), format: .gzip) == Data("a".utf8))
        #expect(try Decode.all(Self.member(Data(), flags: 0), format: .gzip).isEmpty)
    }
}
