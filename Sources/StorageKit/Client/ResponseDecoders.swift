import Foundation
import StorageSigning

/// Pure decoders from parsed XML to models. Unknown elements are ignored; missing optional fields become nil.
enum ResponseDecoders {
    /// URL-decodes listing fields only when the response says `EncodingType=url`.
    struct KeyDecoder {
        let enabled: Bool
        let plusAsSpace: Bool

        init(root: XElement, plusAsSpace: Bool) {
            enabled = root.childText("EncodingType")?.lowercased() == "url"
            self.plusAsSpace = plusAsSpace
        }

        func callAsFunction(_ text: String?) -> String? {
            guard let text else { return nil }
            guard enabled else { return text }
            return PercentEncoding.decode(text, plusAsSpace: plusAsSpace) ?? text
        }
    }

    static func int64(_ text: String?) -> Int64 {
        guard let text, let value = Int64(text.trimmingCharacters(in: .whitespaces)) else { return 0 }
        return max(0, value)
    }

    static func bool(_ text: String?) -> Bool { text?.trimmingCharacters(in: .whitespaces).lowercased() == "true" }

    static func date(_ text: String?) -> Date? { text.flatMap(StorageDate.parseISO8601) }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    static func buckets(_ root: XElement) -> (buckets: [BucketInfo], continuation: String?) {
        let list = (root.child("Buckets")?.children("Bucket") ?? []).compactMap { bucket -> BucketInfo? in
            guard let name = nonEmpty(bucket.childText("Name")) else { return nil }
            return BucketInfo(name: name, creationDate: date(bucket.childText("CreationDate")),
                              region: nonEmpty(bucket.childText("BucketRegion")) ?? nonEmpty(bucket.childText("Region"))
                                  ?? nonEmpty(bucket.childText("Location")),
                              extranetEndpoint: nonEmpty(bucket.childText("ExtranetEndpoint")),
                              intranetEndpoint: nonEmpty(bucket.childText("IntranetEndpoint")),
                              storageClass: nonEmpty(bucket.childText("StorageClass")))
        }
        let truncated = bool(root.childText("IsTruncated"))
        let next = nonEmpty(root.childText("ContinuationToken")) ?? (truncated ? nonEmpty(root.childText("NextMarker")) : nil)
        return (list, next)
    }

    static func listPage(_ root: XElement, plusAsSpace: Bool, version: ListAPIVersion) -> ListPage {
        let decode = KeyDecoder(root: root, plusAsSpace: plusAsSpace)
        let objects = root.children("Contents").compactMap { content -> ObjectEntry? in
            guard let key = decode(content.childText("Key")), !key.isEmpty else { return nil }
            return ObjectEntry(key: key, size: int64(content.childText("Size")), lastModified: date(content.childText("LastModified")),
                               eTag: content.childText("ETag"), storageClass: nonEmpty(content.childText("StorageClass")))
        }
        let prefixes = root.children("CommonPrefixes").compactMap { decode($0.childText("Prefix")) }.filter { !$0.isEmpty }
        let truncated = bool(root.childText("IsTruncated"))
        var token: ListToken?
        if truncated {
            switch version {
            case .v2, .automatic:
                if let next = nonEmpty(root.childText("NextContinuationToken")) { token = .continuation(next) }
            case .v1:
                // NextMarker is only returned with a delimiter; otherwise continue after the greatest key/prefix seen.
                if let next = nonEmpty(decode(root.childText("NextMarker"))) {
                    token = .marker(next)
                } else if let last = (objects.map(\.key) + prefixes).max(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    token = .marker(last)
                }
            }
        }
        return ListPage(objects: objects, commonPrefixes: prefixes, isTruncated: truncated && token != nil, nextToken: token, apiVersion: version)
    }

    static func versionPage(_ root: XElement, plusAsSpace: Bool) -> VersionPage {
        let decode = KeyDecoder(root: root, plusAsSpace: plusAsSpace)
        var versions: [ObjectVersion] = []
        for child in root.children where child.name == "Version" || child.name == "DeleteMarker" {
            guard let key = decode(child.childText("Key")), !key.isEmpty else { continue }
            versions.append(ObjectVersion(key: key, versionID: child.childText("VersionId") ?? "null", isLatest: bool(child.childText("IsLatest")),
                                          isDeleteMarker: child.name == "DeleteMarker", size: int64(child.childText("Size")),
                                          lastModified: date(child.childText("LastModified")), eTag: child.childText("ETag"),
                                          storageClass: nonEmpty(child.childText("StorageClass"))))
        }
        let prefixes = root.children("CommonPrefixes").compactMap { decode($0.childText("Prefix")) }.filter { !$0.isEmpty }
        let truncated = bool(root.childText("IsTruncated"))
        return VersionPage(versions: versions, commonPrefixes: prefixes, isTruncated: truncated,
                           nextKeyMarker: truncated ? nonEmpty(decode(root.childText("NextKeyMarker"))) : nil,
                           nextVersionIDMarker: truncated ? nonEmpty(root.childText("NextVersionIdMarker")) : nil)
    }

    static func uploadsPage(_ root: XElement, plusAsSpace: Bool) -> MultipartUploadsPage {
        let decode = KeyDecoder(root: root, plusAsSpace: plusAsSpace)
        let uploads = root.children("Upload").compactMap { upload -> MultipartUploadInfo? in
            guard let key = decode(upload.childText("Key")), let id = nonEmpty(upload.childText("UploadId")) else { return nil }
            return MultipartUploadInfo(key: key, uploadID: id, initiated: date(upload.childText("Initiated")),
                                       storageClass: nonEmpty(upload.childText("StorageClass")))
        }
        let prefixes = root.children("CommonPrefixes").compactMap { decode($0.childText("Prefix")) }
        let truncated = bool(root.childText("IsTruncated"))
        return MultipartUploadsPage(uploads: uploads, commonPrefixes: prefixes, isTruncated: truncated,
                                    nextKeyMarker: truncated ? nonEmpty(decode(root.childText("NextKeyMarker"))) : nil,
                                    nextUploadIDMarker: truncated ? nonEmpty(root.childText("NextUploadIdMarker")) : nil)
    }

    static func parts(_ root: XElement) -> (parts: [UploadedPart], nextMarker: Int?) {
        let parts = root.children("Part").compactMap { part -> UploadedPart? in
            guard let number = part.childText("PartNumber").flatMap({ Int($0) }), (1...10_000).contains(number),
                  let eTag = nonEmpty(part.childText("ETag")) else { return nil }
            return UploadedPart(partNumber: number, eTag: eTag, size: int64(part.childText("Size")))
        }
        let next = bool(root.childText("IsTruncated")) ? root.childText("NextPartNumberMarker").flatMap { Int($0) } : nil
        return (parts, next)
    }

    static func tags(_ root: XElement) -> [ObjectTag] {
        (root.child("TagSet")?.children("Tag") ?? []).compactMap { tag in
            guard let key = tag.childText("Key") else { return nil }
            return ObjectTag(key: key, value: tag.childText("Value") ?? "")
        }
    }

    static func deleteResult(_ root: XElement) -> DeleteResult {
        // Keys in DeleteResult may be URL-encoded when the request asked for it; we never ask, so read verbatim.
        let deleted = root.children("Deleted").compactMap { item -> ObjectReference? in
            guard let key = item.childText("Key") else { return nil }
            return ObjectReference(key: key, versionID: nonEmpty(item.childText("VersionId")))
        }
        let failures = root.children("Error").map { item in
            DeleteResult.Failure(key: item.childText("Key") ?? "", versionID: nonEmpty(item.childText("VersionId")),
                                 code: item.childText("Code") ?? "Error", message: item.childText("Message") ?? "")
        }
        return DeleteResult(deleted: deleted, failures: failures)
    }

    /// Builds `ObjectMetadata` from HEAD/GET response headers.
    static func metadata(key: String, headers: [String: String], prefix: String) -> ObjectMetadata {
        let metaPrefix = prefix + "meta-"
        var user: [String: String] = [:]
        for (name, value) in headers where name.hasPrefix(metaPrefix) {
            let key = String(name.dropFirst(metaPrefix.count))
            if !key.isEmpty { user[key] = value }
        }
        var size = int64(headers["content-length"])
        if let range = headers["content-range"], let total = contentRangeTotal(range) { size = total }
        return ObjectMetadata(
            key: key, size: size, eTag: headers["etag"], lastModified: headers["last-modified"].flatMap(SigningTime.parseHTTPDate),
            contentType: headers["content-type"], cacheControl: headers["cache-control"], contentDisposition: headers["content-disposition"],
            contentEncoding: headers["content-encoding"], contentLanguage: headers["content-language"], expires: headers["expires"],
            storageClass: headers[prefix + "storage-class"], versionID: nonEmpty(headers[prefix + "version-id"]),
            serverSideEncryption: headers[prefix + "server-side-encryption"],
            kmsKeyID: headers[prefix + "server-side-encryption-aws-kms-key-id"] ?? headers[prefix + "server-side-encryption-key-id"],
            userMetadata: user, tagCount: headers[prefix + "tagging-count"].flatMap { Int($0) },
            partsCount: headers[prefix + "mp-parts-count"].flatMap { Int($0) }, restoreStatus: headers[prefix + "restore"],
            objectType: headers[prefix + "object-type"], isDeleteMarker: headers[prefix + "delete-marker"] == "true", rawHeaders: headers)
    }

    /// `bytes 0-9/443` → 443 (nil for `*` or malformed values).
    static func contentRangeTotal(_ value: String) -> Int64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// `bytes 0-9/443` → (0, 9).
    static func contentRangeBounds(_ value: String) -> (first: Int64, last: Int64)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes "), let slash = trimmed.firstIndex(of: "/") else { return nil }
        let span = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<slash].split(separator: "-")
        guard span.count == 2, let first = Int64(span[0]), let last = Int64(span[1]), first >= 0, last >= first else { return nil }
        return (first, last)
    }
}
