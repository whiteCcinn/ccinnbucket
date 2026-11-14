import Foundation

/// How a file (or object) is split into multipart parts. Pure and total: never traps on any size.
public struct PartPlan: Sendable, Hashable {
    public static let minimumPartSize: Int64 = 5 << 20
    public static let maximumPartSize: Int64 = 5 << 30
    public static let maximumParts = 10_000
    /// Largest object a single PUT may upload.
    public static let maximumSinglePut: Int64 = 5 << 30

    public let totalSize: Int64
    public let partSize: Int64
    public let partCount: Int
    public let usesMultipart: Bool

    /// - Parameters:
    ///   - preferredPartSize: requested part size; raised to 5 MiB and to whatever keeps the plan within 10,000 parts.
    ///   - multipartThreshold: sizes above this use multipart (defaults to the part size).
    public init(totalSize: Int64, preferredPartSize: Int64, multipartThreshold: Int64? = nil) {
        let size = max(0, totalSize)
        let mebibyte: Int64 = 1 << 20
        let neededForCount = size / Int64(Self.maximumParts) + (size % Int64(Self.maximumParts) == 0 ? 0 : 1)
        let roundedNeeded = (neededForCount + mebibyte - 1) / mebibyte * mebibyte
        let partSize = min(Self.maximumPartSize, max(Self.minimumPartSize, max(preferredPartSize, roundedNeeded)))
        let threshold = max(1, multipartThreshold ?? partSize)
        self.totalSize = size
        self.partSize = partSize
        usesMultipart = size > threshold
        if usesMultipart {
            let count = size / partSize + (size % partSize == 0 ? 0 : 1)
            partCount = Int(min(count, Int64(Self.maximumParts)))
        } else {
            partCount = size == 0 ? 0 : 1
        }
    }

    /// Whether the object is too large to transfer at all (more than 10,000 parts of 5 GiB).
    public var exceedsLimits: Bool { Int64(partCount) * partSize < totalSize }

    /// Byte offset and length of 1-based part `number` (nil when out of range).
    public func range(ofPart number: Int) -> (offset: Int64, length: Int64)? {
        guard number >= 1, number <= partCount else { return nil }
        if !usesMultipart { return (0, totalSize) }
        let offset = Int64(number - 1) * partSize
        return (offset, min(partSize, totalSize - offset))
    }

    /// Fixed-size chunks for parallel ranged downloads or copies (`ByteRange`s covering `totalSize`).
    public static func chunks(totalSize: Int64, chunkSize: Int64) -> [ByteRange] {
        guard totalSize > 0 else { return [] }
        let size = max(1 << 20, chunkSize)
        var ranges: [ByteRange] = []
        ranges.reserveCapacity(Int(min(totalSize / size + 1, 1_000_000)))
        var offset: Int64 = 0
        while offset < totalSize {
            let last = min(totalSize, offset + size) - 1
            if let range = ByteRange(first: offset, last: last) { ranges.append(range) }
            offset = last + 1
        }
        return ranges
    }
}

/// Positional reads from a local file (thread-safe: `pread` does not move a shared offset).
public final class LocalFileReader: Sendable {
    private let descriptor: Int32
    public let size: Int64
    public let modificationDate: Date?

    public init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StorageError.localFile("Could not open “\(url.lastPathComponent)”: \(String(cString: strerror(errno))).")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw StorageError.localFile("“\(url.lastPathComponent)” is not a regular file.")
        }
        self.descriptor = descriptor
        size = Int64(info.st_size)
        modificationDate = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
    }

    deinit {
        close(descriptor)
    }

    /// Reads exactly `length` bytes at `offset`; a short read means the file shrank and is an error.
    public func read(offset: Int64, length: Int64) throws -> Data {
        guard offset >= 0, length >= 0, length <= Int64(Int32.max) else { throw StorageError.localFile("Invalid read range.") }
        var data = Data(count: Int(length))
        let total = data.count
        let done = data.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var done = 0
            while done < total {
                let result = pread(descriptor, base.advanced(by: done), total - done, off_t(offset) + off_t(done))
                if result < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                if result == 0 { break }
                done += result
            }
            return done
        }
        guard done == total else {
            throw StorageError.localFile(done < 0 ? "Could not read the file: \(String(cString: strerror(errno)))." : "The file changed while it was being uploaded.")
        }
        return data
    }
}
