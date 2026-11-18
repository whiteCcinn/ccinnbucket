import Foundation

/// CRC-32 (ISO-HDLC, polynomial 0xEDB88320), as used by gzip trailers and FHCRC.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ bytes: some Collection<UInt8>) {
        var crc = state
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        state = crc
    }

    mutating func update(_ bytes: UnsafeBufferPointer<UInt8>) {
        var crc = state
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        state = crc
    }

    static func checksum(_ data: some Collection<UInt8>) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }
}

/// XXH64 with seed 0 (Zstandard content checksums use its low 32 bits).
struct XXH64 {
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    private var v1: UInt64 = prime1 &+ prime2
    private var v2: UInt64 = prime2
    private var v3: UInt64 = 0
    private var v4: UInt64 = 0 &- prime1
    private var totalLength: UInt64 = 0
    private var pending: [UInt8] = []

    private static func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
        var acc = accumulator &+ input &* prime2
        acc = (acc << 31) | (acc >> 33)
        return acc &* prime1
    }

    private static func merge(_ accumulator: UInt64, _ value: UInt64) -> UInt64 {
        (accumulator ^ round(0, value)) &* prime1 &+ prime4
    }

    private static func read64(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        return value
    }

    private static func read32(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<4 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        return value
    }

    mutating func update(_ bytes: some Collection<UInt8>) {
        let array = Array(bytes)
        array.withUnsafeBufferPointer { update($0) }
    }

    mutating func update(_ input: UnsafeBufferPointer<UInt8>) {
        totalLength &+= UInt64(input.count)
        var offset = 0
        if !pending.isEmpty {
            let take = min(32 - pending.count, input.count)
            pending.append(contentsOf: input[0..<take])
            offset = take
            guard pending.count == 32 else { return }
            pending.withUnsafeBufferPointer { stripe in consume(stripe, 0) }
            pending.removeAll(keepingCapacity: true)
        }
        while input.count - offset >= 32 {
            consume(input, offset)
            offset += 32
        }
        if offset < input.count { pending.append(contentsOf: input[offset...]) }
    }

    private mutating func consume(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) {
        v1 = Self.round(v1, Self.read64(bytes, offset))
        v2 = Self.round(v2, Self.read64(bytes, offset + 8))
        v3 = Self.round(v3, Self.read64(bytes, offset + 16))
        v4 = Self.round(v4, Self.read64(bytes, offset + 24))
    }

    func digest() -> UInt64 {
        var hash: UInt64
        if totalLength >= 32 {
            hash = ((v1 << 1) | (v1 >> 63)) &+ ((v2 << 7) | (v2 >> 57)) &+ ((v3 << 12) | (v3 >> 52)) &+ ((v4 << 18) | (v4 >> 46))
            hash = Self.merge(hash, v1)
            hash = Self.merge(hash, v2)
            hash = Self.merge(hash, v3)
            hash = Self.merge(hash, v4)
        } else {
            hash = Self.prime5
        }
        hash &+= totalLength
        pending.withUnsafeBufferPointer { rest in
            var offset = 0
            while rest.count - offset >= 8 {
                hash ^= Self.round(0, Self.read64(rest, offset))
                hash = ((hash << 27) | (hash >> 37)) &* Self.prime1 &+ Self.prime4
                offset += 8
            }
            if rest.count - offset >= 4 {
                hash ^= Self.read32(rest, offset) &* Self.prime1
                hash = ((hash << 23) | (hash >> 41)) &* Self.prime2 &+ Self.prime3
                offset += 4
            }
            while offset < rest.count {
                hash ^= UInt64(rest[offset]) &* Self.prime5
                hash = ((hash << 11) | (hash >> 53)) &* Self.prime1
                offset += 1
            }
        }
        hash ^= hash >> 33
        hash &*= Self.prime2
        hash ^= hash >> 29
        hash &*= Self.prime3
        hash ^= hash >> 32
        return hash
    }

    static func hash(_ data: some Collection<UInt8>) -> UInt64 {
        var hasher = XXH64()
        hasher.update(data)
        return hasher.digest()
    }
}

/// Buffered input: appended at the end, consumed from the front, compacted when the consumed part dominates.
struct InputBuffer {
    private(set) var bytes: [UInt8] = []
    /// Index of the first unconsumed byte.
    private(set) var start = 0

    var available: Int { bytes.count - start }
    var isEmpty: Bool { available == 0 }

    mutating func append(_ data: Data) {
        compactIfNeeded()
        bytes.append(contentsOf: data)
    }

    mutating func consume(_ count: Int) {
        start = min(bytes.count, start + max(0, count))
    }

    /// Moves the read position back by up to `count` bytes (only bytes consumed since the last `append`).
    mutating func rewind(_ count: Int) {
        start = max(0, start - max(0, count))
    }

    /// Byte `index` after the read position, or nil beyond the buffered input.
    func byte(at index: Int) -> UInt8? {
        let absolute = start + index
        guard index >= 0, absolute < bytes.count else { return nil }
        return bytes[absolute]
    }

    private mutating func compactIfNeeded() {
        guard start > 0, start >= 1 << 16, start * 2 >= bytes.count else { return }
        bytes.removeFirst(start)
        start = 0
    }
}
