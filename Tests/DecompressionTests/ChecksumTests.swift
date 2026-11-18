@testable import Decompression
import Foundation
import Testing

@Suite("CRC-32 and XXH64")
struct ChecksumTests {
    @Test("CRC-32 check value and incremental updates")
    func crc32() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
        var crc = CRC32()
        crc.update(Data("1234".utf8))
        crc.update(Data("56789".utf8))
        #expect(crc.value == 0xCBF4_3926)
    }

    @Test("XXH64 reference values; streaming equals one shot for every split")
    func xxh64() {
        #expect(XXH64.hash(Data()) == 0xEF46_DB37_51D8_E999)
        #expect(XXH64.hash(Data("abc".utf8)) == 0x44BC_2CF5_AD77_0999)
        let input = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let expected = XXH64.hash(input)
        for split in [0, 1, 3, 31, 32, 33, 64, 500, 999, 1000] {
            var hasher = XXH64()
            hasher.update(input.prefix(split))
            hasher.update(input.dropFirst(split))
            #expect(hasher.digest() == expected, "split \(split)")
        }
    }
}
