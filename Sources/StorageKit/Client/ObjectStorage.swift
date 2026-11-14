import Foundation

/// Static facts about a provider, so the UI can adapt without knowing which backend is used.
public struct StorageCapabilities: Sendable, Hashable {
    public var provider: StorageProvider
    public var storageClasses: [String]
    public var defaultStorageClass: String
    /// Largest object a single server-side copy can handle (larger copies use multipart copy).
    public var maxSingleCopySize: Int64
    /// Longest presigned-URL lifetime, in seconds.
    public var maxPresignExpiry: Int

    public init(provider: StorageProvider, storageClasses: [String], defaultStorageClass: String, maxSingleCopySize: Int64, maxPresignExpiry: Int) {
        self.provider = provider
        self.storageClasses = storageClasses
        self.defaultStorageClass = defaultStorageClass
        self.maxSingleCopySize = maxSingleCopySize
        self.maxPresignExpiry = maxPresignExpiry
    }
}

/// Provider-neutral bucket and object operations. Implemented by `ObjectStorageClient` for S3 and OSS,
/// and wrapped by `ReadOnlyStorage` for read-only accounts.
public protocol ObjectStorage: Sendable {
    var capabilities: StorageCapabilities { get }
    var isReadOnly: Bool { get }

    // Buckets
    func listBuckets() async throws -> [BucketInfo]
    func createBucket(_ name: String, region: String?) async throws
    func deleteBucket(_ name: String) async throws
    func bucketLocation(_ bucket: String) async throws -> String?
    func headBucket(_ bucket: String) async throws

    // Listing
    func listObjects(_ request: ListObjectsRequest) async throws -> ListPage
    func listObjectVersions(_ request: VersionListRequest) async throws -> VersionPage
    func listMultipartUploads(bucket: String, prefix: String, keyMarker: String?, uploadIDMarker: String?) async throws -> MultipartUploadsPage

    // Objects
    func headObject(bucket: String, key: String, versionID: String?) async throws -> ObjectMetadata
    /// Bounded in-memory GET (previews). Ranged when `range` is given; fails beyond `maxBytes`.
    func getObject(bucket: String, key: String, versionID: String?, range: ByteRange?, maxBytes: Int) async throws -> ObjectData
    /// Streams the body (or a range of it) into an open file descriptor at `fileOffset`.
    func downloadObject(bucket: String, key: String, versionID: String?, range: ByteRange?, ifMatch: String?,
                        descriptor: Int32, fileOffset: Int64, progress: TransferProgressHandler?) async throws -> ObjectMetadata
    func putObject(bucket: String, key: String, body: Data, options: ObjectWriteOptions,
                   progress: TransferProgressHandler?) async throws -> PutResult
    func deleteObject(bucket: String, key: String, versionID: String?) async throws
    /// Deletes up to 1,000 objects in one request; keys that cannot be expressed in XML are deleted individually.
    func deleteObjects(bucket: String, objects: [ObjectReference]) async throws -> DeleteResult
    func copyObject(_ request: CopyObjectRequest) async throws -> PutResult
    func getObjectTags(bucket: String, key: String, versionID: String?) async throws -> [ObjectTag]
    func putObjectTags(bucket: String, key: String, versionID: String?, tags: [ObjectTag]) async throws

    // Multipart
    func createMultipartUpload(bucket: String, key: String, options: ObjectWriteOptions) async throws -> String
    func uploadPart(bucket: String, key: String, uploadID: String, partNumber: Int, body: Data,
                    progress: TransferProgressHandler?) async throws -> UploadedPart
    func uploadPartCopy(bucket: String, key: String, uploadID: String, partNumber: Int, sourceBucket: String,
                        sourceKey: String, sourceVersionID: String?, range: ByteRange) async throws -> UploadedPart
    func completeMultipartUpload(bucket: String, key: String, uploadID: String, parts: [UploadedPart]) async throws -> PutResult
    func abortMultipartUpload(bucket: String, key: String, uploadID: String) async throws
    func listParts(bucket: String, key: String, uploadID: String) async throws -> [UploadedPart]

    // Bucket settings
    func bucketSetting(_ kind: BucketSettingKind, bucket: String) async throws -> BucketSettingDocument
    func versioningStatus(bucket: String) async throws -> VersioningStatus
    func setVersioning(bucket: String, enabled: Bool) async throws

    // Sharing
    func presignedURL(bucket: String, key: String, versionID: String?, method: String, expires: Int,
                      responseContentDisposition: String?) async throws -> URL
}

/// Decorator that refuses every mutating operation before any request is sent.
public struct ReadOnlyStorage: ObjectStorage {
    public let base: any ObjectStorage

    public init(_ base: any ObjectStorage) {
        self.base = base
    }

    public var capabilities: StorageCapabilities { base.capabilities }
    public var isReadOnly: Bool { true }

    public func listBuckets() async throws -> [BucketInfo] { try await base.listBuckets() }
    public func createBucket(_ name: String, region: String?) async throws { throw StorageError.readOnly }
    public func deleteBucket(_ name: String) async throws { throw StorageError.readOnly }
    public func bucketLocation(_ bucket: String) async throws -> String? { try await base.bucketLocation(bucket) }
    public func headBucket(_ bucket: String) async throws { try await base.headBucket(bucket) }

    public func listObjects(_ request: ListObjectsRequest) async throws -> ListPage { try await base.listObjects(request) }
    public func listObjectVersions(_ request: VersionListRequest) async throws -> VersionPage { try await base.listObjectVersions(request) }
    public func listMultipartUploads(bucket: String, prefix: String, keyMarker: String?, uploadIDMarker: String?) async throws -> MultipartUploadsPage {
        try await base.listMultipartUploads(bucket: bucket, prefix: prefix, keyMarker: keyMarker, uploadIDMarker: uploadIDMarker)
    }

    public func headObject(bucket: String, key: String, versionID: String?) async throws -> ObjectMetadata {
        try await base.headObject(bucket: bucket, key: key, versionID: versionID)
    }

    public func getObject(bucket: String, key: String, versionID: String?, range: ByteRange?, maxBytes: Int) async throws -> ObjectData {
        try await base.getObject(bucket: bucket, key: key, versionID: versionID, range: range, maxBytes: maxBytes)
    }

    public func downloadObject(bucket: String, key: String, versionID: String?, range: ByteRange?, ifMatch: String?,
                               descriptor: Int32, fileOffset: Int64, progress: TransferProgressHandler?) async throws -> ObjectMetadata {
        try await base.downloadObject(bucket: bucket, key: key, versionID: versionID, range: range, ifMatch: ifMatch,
                                      descriptor: descriptor, fileOffset: fileOffset, progress: progress)
    }

    public func putObject(bucket: String, key: String, body: Data, options: ObjectWriteOptions,
                          progress: TransferProgressHandler?) async throws -> PutResult { throw StorageError.readOnly }
    public func deleteObject(bucket: String, key: String, versionID: String?) async throws { throw StorageError.readOnly }
    public func deleteObjects(bucket: String, objects: [ObjectReference]) async throws -> DeleteResult { throw StorageError.readOnly }
    public func copyObject(_ request: CopyObjectRequest) async throws -> PutResult { throw StorageError.readOnly }
    public func getObjectTags(bucket: String, key: String, versionID: String?) async throws -> [ObjectTag] {
        try await base.getObjectTags(bucket: bucket, key: key, versionID: versionID)
    }
    public func putObjectTags(bucket: String, key: String, versionID: String?, tags: [ObjectTag]) async throws { throw StorageError.readOnly }

    public func createMultipartUpload(bucket: String, key: String, options: ObjectWriteOptions) async throws -> String { throw StorageError.readOnly }
    public func uploadPart(bucket: String, key: String, uploadID: String, partNumber: Int, body: Data,
                           progress: TransferProgressHandler?) async throws -> UploadedPart { throw StorageError.readOnly }
    public func uploadPartCopy(bucket: String, key: String, uploadID: String, partNumber: Int, sourceBucket: String,
                               sourceKey: String, sourceVersionID: String?, range: ByteRange) async throws -> UploadedPart { throw StorageError.readOnly }
    public func completeMultipartUpload(bucket: String, key: String, uploadID: String, parts: [UploadedPart]) async throws -> PutResult {
        throw StorageError.readOnly
    }
    public func abortMultipartUpload(bucket: String, key: String, uploadID: String) async throws { throw StorageError.readOnly }
    public func listParts(bucket: String, key: String, uploadID: String) async throws -> [UploadedPart] {
        try await base.listParts(bucket: bucket, key: key, uploadID: uploadID)
    }

    public func bucketSetting(_ kind: BucketSettingKind, bucket: String) async throws -> BucketSettingDocument {
        try await base.bucketSetting(kind, bucket: bucket)
    }
    public func versioningStatus(bucket: String) async throws -> VersioningStatus { try await base.versioningStatus(bucket: bucket) }
    public func setVersioning(bucket: String, enabled: Bool) async throws { throw StorageError.readOnly }

    public func presignedURL(bucket: String, key: String, versionID: String?, method: String, expires: Int,
                             responseContentDisposition: String?) async throws -> URL {
        guard method.uppercased() == "GET" || method.uppercased() == "HEAD" else { throw StorageError.readOnly }
        return try await base.presignedURL(bucket: bucket, key: key, versionID: versionID, method: method, expires: expires,
                                           responseContentDisposition: responseContentDisposition)
    }
}
