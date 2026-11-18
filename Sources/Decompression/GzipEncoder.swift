import Compression
import Foundation

/// gzip writer: a single member (no name, mtime 0) whose raw DEFLATE body comes from Apple's Compression framework.
enum GzipEncoder {
    static func compress(_ data: Data) throws -> Data {
        var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(try deflate(data))
        let crc = CRC32.checksum(data)
        let size = UInt32(truncatingIfNeeded: data.count)
        for value in [crc, size] {
            for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
        }
        return output
    }

    /// Raw DEFLATE (RFC 1951) via a streaming encoder, so no output size has to be guessed.
    private static func deflate(_ data: Data) throws -> Data {
        // An empty input is one final fixed-Huffman block holding only end-of-block.
        guard !data.isEmpty else { return Data([0x03, 0x00]) }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw DecompressionError.unsupported("the deflate encoder is unavailable")
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 1 << 16
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { destination.deallocate() }
        var output = Data()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count
            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(destination, count: chunk - stream.pointee.dst_size)
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK: continue
                default: throw DecompressionError.corrupt("deflate encoding failed")
                }
            }
        }
        return output
    }
}
