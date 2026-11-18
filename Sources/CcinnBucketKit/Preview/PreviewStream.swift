import Decompression
import Foundation
import StorageKit

/// How far a preview download has got.
public struct PreviewProgress: Sendable, Equatable {
    /// Bytes of the object downloaded so far (compressed bytes for compressed objects).
    public var receivedBytes: Int64
    /// Size of the object.
    public var totalBytes: Int64
    /// Bytes available to show (decompressed bytes for compressed objects).
    public var decodedBytes: Int64
    /// The format being decompressed, or `nil` for plain content.
    public var compression: CompressionFormat?

    public init(receivedBytes: Int64, totalBytes: Int64, decodedBytes: Int64, compression: CompressionFormat?) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.decodedBytes = decodedBytes
        self.compression = compression
    }

    /// Downloaded fraction of the object, 0…1.
    public var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : 1
    }
}

/// The content shown so far: always the beginning of the object.
public struct PreviewSnapshot: Sendable {
    /// Decoded bytes from the start of the object.
    public var data: Data
    /// The whole object was read and decoded.
    public var isComplete: Bool
    public var progress: PreviewProgress
    /// ETag of the version being shown (to detect changes before saving an edit).
    public var eTag: String?
    /// The structure of the compressed stream read so far (`nil` for plain content).
    public var container: ContainerInfo?
    /// The provider's object type (OSS `Appendable`, `Normal`, `Multipart`), when reported.
    public var objectType: String?
}

/// Streams the beginning of an object for preview: ranged GETs that grow from `chunkSize` to `maxChunkSize`,
/// decompressed on the fly for gzip and Zstandard, with progress after every chunk. `load(upTo:)` can be called
/// again with a larger limit to continue where it stopped (nothing is downloaded twice). Memory is bounded by the
/// limit plus one chunk and the decoder's window.
public actor PreviewStream {
    public enum StreamError: Error, Equatable, LocalizedError {
        /// The object was replaced while it was being read.
        case objectChanged
        /// Many megabytes were read without decoding anything (damaged or hostile data).
        case noProgress

        public var errorDescription: String? {
            switch self {
            case .objectChanged: "The object changed on the server while it was being read. Open the preview again to see the new version."
            case .noProgress: "No content could be decoded from the beginning of this object, so the preview stopped downloading it."
            }
        }
    }

    private let storage: any ObjectStorage
    private let bucket: String
    private let key: String
    private let versionID: String?
    private var size: Int64
    private var compression: CompressionFormat?
    private let makeDecoder: @Sendable (CompressionFormat) -> any StreamDecoder
    private var decoder: (any StreamDecoder)?
    private var chunkSize: Int
    private let maxChunkSize: Int
    private var nextOffset: Int64 = 0
    private var decoded = Data()
    private var finished = false
    private var sniffed = false
    private var eTag: String?
    private var objectType: String?
    private let maxInputWithoutOutput: Int64
    /// Bytes downloaded when the decoded size last grew.
    private var receivedAtLastOutput: Int64 = 0
    private var decodedAtLastCheck = 0

    /// - Parameters:
    ///   - size: the object size from the listing (corrected by the first response).
    ///   - compression: the format expected from the key; checked against the first bytes.
    ///   - makeDecoder: decoder factory (tests inject one).
    public init(storage: any ObjectStorage, bucket: String, key: String, versionID: String?, size: Int64,
                compression: CompressionFormat?, chunkSize: Int = 256 << 10, maxChunkSize: Int = 4 << 20,
                maxInputWithoutOutput: Int = 64 << 20, makeDecoder: (@Sendable (CompressionFormat) -> any StreamDecoder)? = nil) {
        self.storage = storage
        self.bucket = bucket
        self.key = key
        self.versionID = versionID
        self.size = max(0, size)
        self.compression = compression
        self.chunkSize = max(1, chunkSize)
        self.maxChunkSize = max(chunkSize, maxChunkSize)
        self.maxInputWithoutOutput = Int64(max(1, maxInputWithoutOutput))
        self.makeDecoder = makeDecoder ?? { $0.makeDecoder() }
    }

    /// Reads and decodes until at least `limit` bytes are available or the object ends.
    public func load(upTo limit: Int, progress: @escaping @Sendable (PreviewProgress) -> Void = { _ in }) async throws -> PreviewSnapshot {
        while decoded.count < limit, !finished {
            try Task.checkCancellation()
            if let decoder {
                let endOfInput = nextOffset >= size
                switch try decoder.decode(into: &decoded, maxOutput: max(1, limit - decoded.count), endOfInput: endOfInput) {
                case .finished:
                    finished = true
                    continue
                case .outputFull:
                    continue
                case .needsInput:
                    // A decoder that wants more input after the last byte has a truncated stream.
                    if endOfInput { throw DecompressionError.truncated }
                }
            } else if nextOffset >= size {
                finished = true
                continue
            }
            if decoded.count != decodedAtLastCheck {
                decodedAtLastCheck = decoded.count
                receivedAtLastOutput = nextOffset
            } else if decoder != nil, nextOffset - receivedAtLastOutput >= maxInputWithoutOutput {
                throw StreamError.noProgress
            }
            try await fetchNextChunk()
            progress(currentProgress)
        }
        return PreviewSnapshot(data: decoded, isComplete: finished, progress: currentProgress, eTag: eTag, container: decoder?.container,
                               objectType: objectType)
    }

    private var currentProgress: PreviewProgress {
        PreviewProgress(receivedBytes: nextOffset, totalBytes: size, decodedBytes: Int64(decoded.count), compression: compression)
    }

    private func fetchNextChunk() async throws {
        let length = min(Int64(chunkSize), size - nextOffset)
        guard length > 0, let range = ByteRange(first: nextOffset, last: nextOffset + length - 1) else {
            throw StorageError.invalidResponse("The preview range is empty.")
        }
        let object = try await storage.getObject(bucket: bucket, key: key, versionID: versionID, range: range, maxBytes: Int(length))
        try Task.checkCancellation()
        if let known = eTag, let current = object.metadata.eTag, !ObjectTextSaver.sameETag(known, current) {
            throw StreamError.objectChanged
        }
        eTag = eTag ?? object.metadata.eTag
        objectType = objectType ?? object.metadata.objectType
        guard !object.data.isEmpty else { throw StorageError.invalidResponse("The server returned no bytes for \(key).") }
        if nextOffset == 0, object.totalSize > 0 { size = object.totalSize }
        nextOffset += Int64(object.data.count)
        chunkSize = min(chunkSize * 2, maxChunkSize)
        if !sniffed {
            sniffed = true
            // Trust the bytes over the name: a `.gz` that is not gzip (already decoded by the transport, or misnamed)
            // is shown as it is, and a mislabelled format is decoded as what it really is.
            if compression != nil { compression = CompressionFormat.sniff(object.data) }
            decoder = compression.map(makeDecoder)
        }
        if let decoder {
            decoder.feed(object.data)
        } else {
            decoded.append(object.data)
        }
    }
}
