import Decompression
import Foundation
import StorageKit

/// Writes an edited text preview back to its object: re-compressed in the original format, with every header, user
/// metadata, storage class, encryption setting and tag kept, and only if the object is still the version that was
/// opened (so an edit never silently overwrites someone else's change).
public enum ObjectTextSaver {
    public enum SaveError: Error, Equatable, LocalizedError {
        /// The object's ETag differs from the one the edit started from.
        case changedOnServer
        /// The object has tags that could not be read, so saving would drop them.
        case tagsUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .changedOnServer:
                "The object was changed on the server after you opened it. Your edit was not saved; reopen the preview to edit the current version."
            case let .tagsUnavailable(reason):
                "The object's tags could not be read, so saving would remove them. Nothing was saved. (\(reason))"
            }
        }
    }

    /// The bytes to upload for `text`: UTF-8, compressed in `compression` when the object is compressed.
    public static func encode(_ text: String, compression: CompressionFormat?) throws -> Data {
        let data = Data(text.utf8)
        guard let compression else { return data }
        return try compression.compress(data)
    }

    /// Replaces the object with `body` if its ETag still matches `expectedETag`.
    @discardableResult
    public static func save(body: Data, bucket: String, key: String, expectedETag: String?,
                            storage: any ObjectStorage) async throws -> PutResult {
        // Tags are always read: AWS S3's HeadObject does not report a tag count, and a PUT without tags removes them.
        // They are read before the ETag check so the check happens right before the upload.
        let tags: [ObjectTag]
        do {
            tags = try await storage.getObjectTags(bucket: bucket, key: key, versionID: nil)
        } catch {
            let wrapped = StorageError.wrap(error)
            // Services without object tagging have no tags to lose.
            guard ["NotImplemented", "MethodNotAllowed", "NotSupported"].contains(wrapped.code ?? "") || wrapped.statusCode == 501 else {
                throw SaveError.tagsUnavailable(wrapped.description)
            }
            tags = []
        }
        let current = try await storage.headObject(bucket: bucket, key: key, versionID: nil)
        guard let expectedETag, sameETag(expectedETag, current.eTag) else { throw SaveError.changedOnServer }
        let options = ObjectWriteOptions(contentType: current.contentType, cacheControl: current.cacheControl,
                                         contentDisposition: current.contentDisposition, contentEncoding: current.contentEncoding,
                                         contentLanguage: current.contentLanguage, expires: current.expires,
                                         storageClass: current.storageClass, userMetadata: current.userMetadata, tags: tags,
                                         serverSideEncryption: current.serverSideEncryption, kmsKeyID: current.kmsKeyID)
        return try await storage.putObject(bucket: bucket, key: key, body: body, options: options, progress: nil)
    }

    /// ETags compared without quotes, weak prefix and case.
    public static func sameETag(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ eTag: String) -> String {
        var value = eTag.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
    }
}
