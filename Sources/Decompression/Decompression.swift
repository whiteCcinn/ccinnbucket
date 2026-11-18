import Foundation

/// Compressed formats CcinnBucket can preview and save: gzip (RFC 1952) and Zstandard (RFC 8878).
public enum CompressionFormat: String, Sendable, CaseIterable, Hashable {
    case gzip
    case zstd

    /// `gz`, `gzip`, `tgz` → gzip; `zst`, `zstd`, `tzst` → zstd (case-insensitive).
    public static func fromExtension(_ fileExtension: String) -> CompressionFormat? {
        switch fileExtension.lowercased() {
        case "gz", "gzip", "tgz": .gzip
        case "zst", "zstd", "tzst": .zstd
        default: nil
        }
    }

    /// From the first bytes of the data: `1F 8B` → gzip, `28 B5 2F FD` → zstd.
    public static func sniff(_ prefix: Data) -> CompressionFormat? {
        let bytes = [UInt8](prefix.prefix(4))
        if bytes.count >= 2, bytes[0] == 0x1F, bytes[1] == 0x8B { return .gzip }
        if bytes.count >= 4, bytes == [0x28, 0xB5, 0x2F, 0xFD] { return .zstd }
        return nil
    }

    public var displayName: String {
        switch self {
        case .gzip: "gzip"
        case .zstd: "Zstandard"
        }
    }

    /// A new incremental decoder for this format.
    public func makeDecoder() -> any StreamDecoder {
        switch self {
        case .gzip: GzipDecoder()
        case .zstd: ZstdDecoder()
        }
    }

    /// Compresses a whole buffer in this format (used when saving an edited preview).
    public func compress(_ data: Data) throws -> Data {
        switch self {
        case .gzip: try GzipEncoder.compress(data)
        case .zstd: try ZstdEncoder.compress(data)
        }
    }
}

public enum DecompressionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The data is not valid for the format (bad magic, header, table, checksum, …).
    case corrupt(String)
    /// Valid but not supported (for example a zstd frame that needs a dictionary).
    case unsupported(String)
    /// The input ended in the middle of a frame or member.
    case truncated

    public var description: String {
        switch self {
        case let .corrupt(reason): "The compressed data is damaged: \(reason)."
        case let .unsupported(reason): "Not supported: \(reason)."
        case .truncated: "The compressed data ends unexpectedly."
        }
    }
}

/// How the stream decoded so far is built, for deciding whether re-compressing it would lose structure.
public struct ContainerInfo: Equatable, Sendable {
    /// gzip members or Zstandard frames started.
    public var units: Int
    /// Zstandard skippable frames (seek tables of the seekable format, metadata).
    public var skippableFrames: Int
    /// A gzip header carried an extra field (BGZF/tabix indexes rely on it).
    public var hasExtraField: Bool

    public init(units: Int = 0, skippableFrames: Int = 0, hasExtraField: Bool = false) {
        self.units = units
        self.skippableFrames = skippableFrames
        self.hasExtraField = hasExtraField
    }
}

/// What `StreamDecoder.decode` stopped on.
public enum DecodeState: Equatable, Sendable {
    /// All buffered input was used and the stream is not finished: feed more.
    case needsInput
    /// About `maxOutput` bytes were produced; call again to continue.
    case outputFull
    /// Every frame or member ended and `endOfInput` was set.
    case finished
}

/// Incremental decoder: feed compressed bytes as they arrive and take decoded bytes as they are produced. Memory
/// stays bounded (buffered input plus the format's history window), so arbitrarily large objects can be previewed
/// from their beginning. Never traps on malformed input: every problem is a thrown `DecompressionError`.
public protocol StreamDecoder: AnyObject {
    /// Appends compressed input.
    func feed(_ data: Data)

    /// Decodes buffered input and appends the decoded bytes to `output`.
    /// - Parameters:
    ///   - maxOutput: stop after about this many new bytes (zstd may exceed it by at most one block, 128 KiB).
    ///   - endOfInput: no more input will be fed; a stream that ends mid-frame throws `.truncated`.
    func decode(into output: inout Data, maxOutput: Int, endOfInput: Bool) throws -> DecodeState

    /// The structure seen so far.
    var container: ContainerInfo { get }
}

extension StreamDecoder {
    public var container: ContainerInfo { ContainerInfo() }
}
