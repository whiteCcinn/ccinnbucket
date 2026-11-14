import Foundation

public enum StorageProvider: String, Codable, Sendable, Hashable, CaseIterable {
    /// Amazon S3 and S3-compatible services (MinIO, R2, Ceph RGW, Wasabi, COS S3 API, …).
    case s3
    /// Alibaba Cloud Object Storage Service (native API).
    case oss
}

public struct BucketInfo: Sendable, Hashable, Identifiable {
    public var name: String
    public var creationDate: Date?
    /// Region id (`eu-west-1`, `cn-hangzhou`) when the service reports it.
    public var region: String?
    /// OSS public endpoint for the bucket (e.g. `oss-cn-hangzhou.aliyuncs.com`).
    public var extranetEndpoint: String?
    public var intranetEndpoint: String?
    public var storageClass: String?

    public var id: String { name }

    public init(name: String, creationDate: Date? = nil, region: String? = nil, extranetEndpoint: String? = nil,
                intranetEndpoint: String? = nil, storageClass: String? = nil) {
        self.name = name
        self.creationDate = creationDate
        self.region = region
        self.extranetEndpoint = extranetEndpoint
        self.intranetEndpoint = intranetEndpoint
        self.storageClass = storageClass
    }
}

/// One object in a listing.
public struct ObjectEntry: Sendable, Hashable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
    public var eTag: String?
    public var storageClass: String?

    public init(key: String, size: Int64, lastModified: Date? = nil, eTag: String? = nil, storageClass: String? = nil) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.storageClass = storageClass
    }

    /// Zero-byte `prefix/` placeholder created by consoles and tools to represent folders.
    public var isFolderMarker: Bool { key.hasSuffix("/") && size == 0 }
}

public enum ListToken: Sendable, Hashable {
    /// ListObjectsV2 `continuation-token`.
    case continuation(String)
    /// ListObjects (V1) `marker`.
    case marker(String)
}

public enum ListAPIVersion: String, Codable, Sendable, Hashable, CaseIterable {
    case automatic
    case v2
    case v1
}

public struct ListObjectsRequest: Sendable, Hashable {
    public var bucket: String
    public var prefix: String
    public var delimiter: String?
    public var token: ListToken?
    public var maxKeys: Int

    public init(bucket: String, prefix: String = "", delimiter: String? = "/", token: ListToken? = nil, maxKeys: Int = 1000) {
        self.bucket = bucket
        self.prefix = prefix
        self.delimiter = delimiter
        self.token = token
        self.maxKeys = min(max(maxKeys, 1), 1000)
    }
}

public struct ListPage: Sendable, Hashable {
    public var objects: [ObjectEntry]
    public var commonPrefixes: [String]
    public var isTruncated: Bool
    public var nextToken: ListToken?
    /// The API that produced the page (V1 after a fallback).
    public var apiVersion: ListAPIVersion

    public init(objects: [ObjectEntry], commonPrefixes: [String], isTruncated: Bool, nextToken: ListToken?, apiVersion: ListAPIVersion) {
        self.objects = objects
        self.commonPrefixes = commonPrefixes
        self.isTruncated = isTruncated
        self.nextToken = nextToken
        self.apiVersion = apiVersion
    }
}

public struct ObjectVersion: Sendable, Hashable, Identifiable {
    public var key: String
    public var versionID: String
    public var isLatest: Bool
    public var isDeleteMarker: Bool
    public var size: Int64
    public var lastModified: Date?
    public var eTag: String?
    public var storageClass: String?

    public var id: String { key + "\u{0}" + versionID }

    public init(key: String, versionID: String, isLatest: Bool, isDeleteMarker: Bool, size: Int64 = 0, lastModified: Date? = nil,
                eTag: String? = nil, storageClass: String? = nil) {
        self.key = key
        self.versionID = versionID
        self.isLatest = isLatest
        self.isDeleteMarker = isDeleteMarker
        self.size = size
        self.lastModified = lastModified
        self.eTag = eTag
        self.storageClass = storageClass
    }
}

public struct VersionListRequest: Sendable, Hashable {
    public var bucket: String
    public var prefix: String
    public var delimiter: String?
    public var keyMarker: String?
    public var versionIDMarker: String?
    public var maxKeys: Int

    public init(bucket: String, prefix: String = "", delimiter: String? = "/", keyMarker: String? = nil, versionIDMarker: String? = nil,
                maxKeys: Int = 1000) {
        self.bucket = bucket
        self.prefix = prefix
        self.delimiter = delimiter
        self.keyMarker = keyMarker
        self.versionIDMarker = versionIDMarker
        self.maxKeys = min(max(maxKeys, 1), 1000)
    }
}

public struct VersionPage: Sendable, Hashable {
    public var versions: [ObjectVersion]
    public var commonPrefixes: [String]
    public var isTruncated: Bool
    public var nextKeyMarker: String?
    public var nextVersionIDMarker: String?

    public init(versions: [ObjectVersion], commonPrefixes: [String], isTruncated: Bool, nextKeyMarker: String?, nextVersionIDMarker: String?) {
        self.versions = versions
        self.commonPrefixes = commonPrefixes
        self.isTruncated = isTruncated
        self.nextKeyMarker = nextKeyMarker
        self.nextVersionIDMarker = nextVersionIDMarker
    }
}

public struct MultipartUploadInfo: Sendable, Hashable, Identifiable {
    public var key: String
    public var uploadID: String
    public var initiated: Date?
    public var storageClass: String?

    public var id: String { uploadID }

    public init(key: String, uploadID: String, initiated: Date? = nil, storageClass: String? = nil) {
        self.key = key
        self.uploadID = uploadID
        self.initiated = initiated
        self.storageClass = storageClass
    }
}

public struct MultipartUploadsPage: Sendable, Hashable {
    public var uploads: [MultipartUploadInfo]
    public var commonPrefixes: [String]
    public var isTruncated: Bool
    public var nextKeyMarker: String?
    public var nextUploadIDMarker: String?

    public init(uploads: [MultipartUploadInfo], commonPrefixes: [String], isTruncated: Bool, nextKeyMarker: String?, nextUploadIDMarker: String?) {
        self.uploads = uploads
        self.commonPrefixes = commonPrefixes
        self.isTruncated = isTruncated
        self.nextKeyMarker = nextKeyMarker
        self.nextUploadIDMarker = nextUploadIDMarker
    }
}

public struct UploadedPart: Codable, Sendable, Hashable {
    public var partNumber: Int
    public var eTag: String
    public var size: Int64

    public init(partNumber: Int, eTag: String, size: Int64) {
        self.partNumber = partNumber
        self.eTag = eTag
        self.size = size
    }
}

/// Identifies one object (optionally one specific version).
public struct ObjectReference: Sendable, Hashable {
    public var key: String
    public var versionID: String?

    public init(key: String, versionID: String? = nil) {
        self.key = key
        self.versionID = versionID
    }
}

public struct DeleteResult: Sendable, Hashable {
    public struct Failure: Sendable, Hashable {
        public var key: String
        public var versionID: String?
        public var code: String
        public var message: String
    }

    public var deleted: [ObjectReference]
    public var failures: [Failure]

    public init(deleted: [ObjectReference] = [], failures: [Failure] = []) {
        self.deleted = deleted
        self.failures = failures
    }
}

public struct PutResult: Sendable, Hashable {
    public var eTag: String?
    public var versionID: String?

    public init(eTag: String? = nil, versionID: String? = nil) {
        self.eTag = eTag
        self.versionID = versionID
    }
}

public struct ObjectTag: Sendable, Hashable, Codable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Headers describing an object, from HEAD / GET.
public struct ObjectMetadata: Sendable, Hashable {
    public var key: String
    public var size: Int64
    public var eTag: String?
    public var lastModified: Date?
    public var contentType: String?
    public var cacheControl: String?
    public var contentDisposition: String?
    public var contentEncoding: String?
    public var contentLanguage: String?
    public var expires: String?
    public var storageClass: String?
    public var versionID: String?
    public var serverSideEncryption: String?
    public var kmsKeyID: String?
    public var userMetadata: [String: String]
    public var tagCount: Int?
    public var partsCount: Int?
    public var restoreStatus: String?
    public var objectType: String?
    public var isDeleteMarker: Bool
    /// All response headers (lower-cased), for the "raw headers" section.
    public var rawHeaders: [String: String]

    public init(key: String, size: Int64 = 0, eTag: String? = nil, lastModified: Date? = nil, contentType: String? = nil,
                cacheControl: String? = nil, contentDisposition: String? = nil, contentEncoding: String? = nil,
                contentLanguage: String? = nil, expires: String? = nil, storageClass: String? = nil, versionID: String? = nil,
                serverSideEncryption: String? = nil, kmsKeyID: String? = nil, userMetadata: [String: String] = [:],
                tagCount: Int? = nil, partsCount: Int? = nil, restoreStatus: String? = nil, objectType: String? = nil,
                isDeleteMarker: Bool = false, rawHeaders: [String: String] = [:]) {
        self.key = key
        self.size = size
        self.eTag = eTag
        self.lastModified = lastModified
        self.contentType = contentType
        self.cacheControl = cacheControl
        self.contentDisposition = contentDisposition
        self.contentEncoding = contentEncoding
        self.contentLanguage = contentLanguage
        self.expires = expires
        self.storageClass = storageClass
        self.versionID = versionID
        self.serverSideEncryption = serverSideEncryption
        self.kmsKeyID = kmsKeyID
        self.userMetadata = userMetadata
        self.tagCount = tagCount
        self.partsCount = partsCount
        self.restoreStatus = restoreStatus
        self.objectType = objectType
        self.isDeleteMarker = isDeleteMarker
        self.rawHeaders = rawHeaders
    }

    /// The writable subset, used to preserve fields during a metadata-replacing self-copy.
    public var writeOptions: ObjectWriteOptions {
        ObjectWriteOptions(contentType: contentType, cacheControl: cacheControl, contentDisposition: contentDisposition,
                           contentEncoding: contentEncoding, contentLanguage: contentLanguage, expires: expires,
                           storageClass: storageClass, userMetadata: userMetadata, serverSideEncryption: serverSideEncryption,
                           kmsKeyID: kmsKeyID)
    }
}

/// Headers to set when writing an object (PUT, CreateMultipartUpload, CopyObject with REPLACE).
public struct ObjectWriteOptions: Sendable, Hashable {
    public var contentType: String?
    public var cacheControl: String?
    public var contentDisposition: String?
    public var contentEncoding: String?
    public var contentLanguage: String?
    public var expires: String?
    public var storageClass: String?
    public var userMetadata: [String: String]
    public var tags: [ObjectTag]
    public var serverSideEncryption: String?
    public var kmsKeyID: String?

    public init(contentType: String? = nil, cacheControl: String? = nil, contentDisposition: String? = nil,
                contentEncoding: String? = nil, contentLanguage: String? = nil, expires: String? = nil, storageClass: String? = nil,
                userMetadata: [String: String] = [:], tags: [ObjectTag] = [], serverSideEncryption: String? = nil,
                kmsKeyID: String? = nil) {
        self.contentType = contentType
        self.cacheControl = cacheControl
        self.contentDisposition = contentDisposition
        self.contentEncoding = contentEncoding
        self.contentLanguage = contentLanguage
        self.expires = expires
        self.storageClass = storageClass
        self.userMetadata = userMetadata
        self.tags = tags
        self.serverSideEncryption = serverSideEncryption
        self.kmsKeyID = kmsKeyID
    }
}

public enum MetadataDirective: String, Sendable, Hashable {
    case copy = "COPY"
    case replace = "REPLACE"
}

public struct CopyObjectRequest: Sendable, Hashable {
    public var sourceBucket: String
    public var sourceKey: String
    public var sourceVersionID: String?
    public var destinationBucket: String
    public var destinationKey: String
    public var directive: MetadataDirective
    /// Used with `.replace`; with `.copy` only `storageClass` is applied.
    public var options: ObjectWriteOptions

    public init(sourceBucket: String, sourceKey: String, sourceVersionID: String? = nil, destinationBucket: String,
                destinationKey: String, directive: MetadataDirective = .copy, options: ObjectWriteOptions = ObjectWriteOptions()) {
        self.sourceBucket = sourceBucket
        self.sourceKey = sourceKey
        self.sourceVersionID = sourceVersionID
        self.destinationBucket = destinationBucket
        self.destinationKey = destinationKey
        self.directive = directive
        self.options = options
    }
}

public enum VersioningStatus: String, Sendable, Hashable {
    case unversioned = "Unversioned"
    case enabled = "Enabled"
    case suspended = "Suspended"
}

/// Inclusive byte range.
public struct ByteRange: Sendable, Hashable {
    public var first: Int64
    public var last: Int64

    public init?(first: Int64, last: Int64) {
        guard first >= 0, last >= first else { return nil }
        self.first = first
        self.last = last
    }

    public var length: Int64 { last - first + 1 }
    public var headerValue: String { "bytes=\(first)-\(last)" }
}

/// A bounded GET result.
public struct ObjectData: Sendable, Hashable {
    public var data: Data
    public var metadata: ObjectMetadata
    /// Total object size (from `Content-Range` for ranged requests).
    public var totalSize: Int64
    public var isPartial: Bool { Int64(data.count) < totalSize }

    public init(data: Data, metadata: ObjectMetadata, totalSize: Int64) {
        self.data = data
        self.metadata = metadata
        self.totalSize = totalSize
    }
}
