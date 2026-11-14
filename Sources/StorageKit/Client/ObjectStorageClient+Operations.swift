import Foundation
import StorageSigning

extension ObjectStorageClient {
    // MARK: Buckets

    public func listBuckets() async throws -> [BucketInfo] {
        var result: [BucketInfo] = []
        var token: String?
        for _ in 0..<1_000 {
            var query: [QueryParameter] = []
            switch configuration.provider {
            case .s3:
                if let token { query.append(QueryParameter("continuation-token", token)) }
            case .oss:
                query.append(QueryParameter("max-keys", "1000"))
                if let token { query.append(QueryParameter("marker", token)) }
            }
            let response = try await execute(Operation(method: "GET", query: query, relocates: false))
            let page = ResponseDecoders.buckets(try xml(response))
            result.append(contentsOf: page.buckets)
            guard let next = page.continuation, next != token else { break }
            token = next
        }
        for bucket in result {
            if let location = dialect.location(of: bucket) { remember(location, for: bucket.name) }
        }
        return result
    }

    public func createBucket(_ name: String, region: String?) async throws {
        let problems = BucketNaming.violations(name, provider: configuration.provider)
        guard problems.isEmpty else { throw StorageError.invalidRequest(problems.joined(separator: " ")) }
        if let region, !region.isEmpty {
            let location = configuration.provider == .oss
                ? BucketLocation(region: OSSDialect.normalizedRegion(region),
                                 endpointHost: OSSDialect.endpointHost(region: OSSDialect.normalizedRegion(region), kind: configuration.ossEndpointKind))
                : BucketLocation(region: region)
            remember(location, for: name)
        }
        let body = dialect.createBucketBody(region: region ?? dialect.defaultLocation.region)
        var headers: [HTTPHeader] = []
        if body != nil { headers.append(HTTPHeader("Content-Type", "application/xml")) }
        _ = try await execute(Operation(method: "PUT", bucket: name, headers: headers, body: body, relocates: false))
    }

    public func deleteBucket(_ name: String) async throws {
        _ = try await execute(Operation(method: "DELETE", bucket: name))
    }

    public func bucketLocation(_ bucket: String) async throws -> String? {
        let response = try await execute(Operation(method: "GET", bucket: bucket, query: [QueryParameter("location")]))
        guard let location = dialect.parseLocationConstraint(try xml(response)) else { return nil }
        remember(location, for: bucket)
        return location.region
    }

    public func headBucket(_ bucket: String) async throws {
        _ = try await execute(Operation(method: "HEAD", bucket: bucket))
    }

    // MARK: Listing

    public func listObjects(_ request: ListObjectsRequest) async throws -> ListPage {
        var version = effectiveListAPIVersion
        if case .marker = request.token { version = .v1 }
        if case .continuation = request.token, version == .v1 { version = .v2 }
        if version == .v1 { return try await listObjects(request, version: .v1) }
        do {
            let page = try await listObjects(request, version: version)
            if effectiveListAPIVersion == .automatic { setListVersion(page.apiVersion) }
            return page
        } catch let error as StorageError where version == .automatic && Self.indicatesV2Unsupported(error) {
            setListVersion(.v1)
            return try await listObjects(request, version: .v1)
        }
    }

    static func indicatesV2Unsupported(_ error: StorageError) -> Bool {
        guard error.kind == .service else { return false }
        if ["NotImplemented", "InvalidArgument", "UnsupportedArgument"].contains(error.code ?? "") { return true }
        return error.statusCode == 501
    }

    private func listObjects(_ request: ListObjectsRequest, version: ListAPIVersion) async throws -> ListPage {
        var query: [QueryParameter] = []
        if version != .v1 { query.append(QueryParameter("list-type", "2")) }
        query.append(QueryParameter("prefix", request.prefix))
        if let delimiter = request.delimiter, !delimiter.isEmpty { query.append(QueryParameter("delimiter", delimiter)) }
        query.append(QueryParameter("encoding-type", "url"))
        query.append(QueryParameter("max-keys", String(request.maxKeys)))
        switch request.token {
        case let .continuation(token)?: query.append(QueryParameter("continuation-token", token))
        case let .marker(marker)?: query.append(QueryParameter("marker", marker))
        case nil: break
        }
        let response = try await execute(Operation(method: "GET", bucket: request.bucket, query: query))
        let root = try xml(response)
        guard root.name == "ListBucketResult" else {
            throw StorageError.invalidResponse("Unexpected listing response <\(root.name)>.")
        }
        // A server that ignores `list-type=2` answers in V1 form (no KeyCount / continuation tokens).
        let answeredV1 = version != .v1 && root.child("KeyCount") == nil && root.child("NextContinuationToken") == nil
            && root.child("ContinuationToken") == nil && (root.child("Marker") != nil || root.child("NextMarker") != nil)
        let effective: ListAPIVersion = (version == .v1 || answeredV1) ? .v1 : .v2
        return ResponseDecoders.listPage(root, plusAsSpace: dialect.listingPlusAsSpace, version: effective)
    }

    public func listObjectVersions(_ request: VersionListRequest) async throws -> VersionPage {
        var query = [QueryParameter("versions"), QueryParameter("prefix", request.prefix)]
        if let delimiter = request.delimiter, !delimiter.isEmpty { query.append(QueryParameter("delimiter", delimiter)) }
        query.append(QueryParameter("encoding-type", "url"))
        query.append(QueryParameter("max-keys", String(request.maxKeys)))
        if let marker = request.keyMarker { query.append(QueryParameter("key-marker", marker)) }
        if let marker = request.versionIDMarker { query.append(QueryParameter("version-id-marker", marker)) }
        let response = try await execute(Operation(method: "GET", bucket: request.bucket, query: query))
        return ResponseDecoders.versionPage(try xml(response), plusAsSpace: dialect.listingPlusAsSpace)
    }

    public func listMultipartUploads(bucket: String, prefix: String, keyMarker: String?, uploadIDMarker: String?) async throws -> MultipartUploadsPage {
        var query = [QueryParameter("uploads"), QueryParameter("encoding-type", "url"), QueryParameter("max-uploads", "1000")]
        if !prefix.isEmpty { query.append(QueryParameter("prefix", prefix)) }
        if let keyMarker { query.append(QueryParameter("key-marker", keyMarker)) }
        if let uploadIDMarker { query.append(QueryParameter("upload-id-marker", uploadIDMarker)) }
        let response = try await execute(Operation(method: "GET", bucket: bucket, query: query))
        return ResponseDecoders.uploadsPage(try xml(response), plusAsSpace: dialect.listingPlusAsSpace)
    }

    // MARK: Objects

    static func validateKey(_ key: String) throws {
        guard !key.isEmpty else { throw StorageError.invalidRequest("The object key is empty.") }
        guard key.utf8.count <= 1024 else { throw StorageError.invalidRequest("Object keys are limited to 1,024 bytes.") }
    }

    private func versionQuery(_ versionID: String?) -> [QueryParameter] {
        guard let versionID, !versionID.isEmpty else { return [] }
        return [QueryParameter("versionId", versionID)]
    }

    public func headObject(bucket: String, key: String, versionID: String?) async throws -> ObjectMetadata {
        try Self.validateKey(key)
        let response = try await execute(Operation(method: "HEAD", bucket: bucket, key: key, query: versionQuery(versionID)))
        return ResponseDecoders.metadata(key: key, headers: response.headers, prefix: dialect.headerPrefix)
    }

    public func getObject(bucket: String, key: String, versionID: String?, range: ByteRange?, maxBytes: Int) async throws -> ObjectData {
        try Self.validateKey(key)
        guard maxBytes > 0 else { throw StorageError.invalidRequest("The preview size limit must be positive.") }
        var headers: [HTTPHeader] = []
        if let range { headers.append(HTTPHeader("Range", range.headerValue)) }
        // Ask the service not to label the body as compressed, so URLSession never transparently inflates it.
        let query = versionQuery(versionID) + [QueryParameter("response-content-encoding", "identity")]
        let response = try await execute(Operation(method: "GET", bucket: bucket, key: key, query: query, headers: headers,
                                                   sink: .memory(limit: maxBytes)))
        let metadata = ResponseDecoders.metadata(key: key, headers: response.headers, prefix: dialect.headerPrefix)
        let total = response.header("content-range").flatMap(ResponseDecoders.contentRangeTotal) ?? Int64(response.body.count)
        return ObjectData(data: response.body, metadata: metadata, totalSize: max(total, Int64(response.body.count)))
    }

    public func downloadObject(bucket: String, key: String, versionID: String?, range: ByteRange?, ifMatch: String?,
                               descriptor: Int32, fileOffset: Int64, progress: TransferProgressHandler?) async throws -> ObjectMetadata {
        try Self.validateKey(key)
        var headers: [HTTPHeader] = []
        if let range { headers.append(HTTPHeader("Range", range.headerValue)) }
        if let ifMatch { headers.append(HTTPHeader("If-Match", ifMatch)) }
        let accepted: Set<Int> = (range.map { $0.first > 0 } ?? false) ? [206] : [200, 206]
        let maxBytes = range?.length ?? Int64.max
        let query = versionQuery(versionID) + [QueryParameter("response-content-encoding", "identity")]
        let response = try await execute(Operation(method: "GET", bucket: bucket, key: key, query: query, headers: headers,
                                                   sink: .file(descriptor: descriptor, offset: fileOffset, maxBytes: maxBytes, acceptedStatuses: accepted),
                                                   progress: progress))
        guard accepted.contains(response.statusCode) else {
            throw StorageError(kind: .invalidResponse, message: "The server ignored the requested byte range.", statusCode: response.statusCode)
        }
        if let range, response.statusCode == 206 {
            guard let bounds = response.header("content-range").flatMap(ResponseDecoders.contentRangeBounds),
                  bounds.first == range.first, bounds.last <= range.last,
                  response.bytesWritten == bounds.last - bounds.first + 1 else {
                throw StorageError.invalidResponse("The server returned a different byte range than requested.")
            }
        } else if let length = response.header("content-length").flatMap({ Int64($0) }), response.bytesWritten != length {
            throw StorageError.invalidResponse("The download ended early (\(response.bytesWritten) of \(length) bytes).")
        }
        return ResponseDecoders.metadata(key: key, headers: response.headers, prefix: dialect.headerPrefix)
    }

    func writeHeaders(_ options: ObjectWriteOptions, defaultContentType: Bool) throws -> [HTTPHeader] {
        var headers: [HTTPHeader] = []
        if let value = options.contentType ?? (defaultContentType ? "application/octet-stream" : nil) { headers.append(HTTPHeader("Content-Type", value)) }
        if let value = options.cacheControl { headers.append(HTTPHeader("Cache-Control", value)) }
        if let value = options.contentDisposition { headers.append(HTTPHeader("Content-Disposition", value)) }
        if let value = options.contentEncoding { headers.append(HTTPHeader("Content-Encoding", value)) }
        if let value = options.contentLanguage { headers.append(HTTPHeader("Content-Language", value)) }
        if let value = options.expires { headers.append(HTTPHeader("Expires", value)) }
        if let value = options.storageClass, !value.isEmpty { headers.append(HTTPHeader(dialect.storageClassHeader, value)) }
        for (name, value) in options.userMetadata.sorted(by: { $0.key < $1.key }) {
            try MetadataRules.validate(key: name, value: value)
            headers.append(HTTPHeader(dialect.metadataPrefix + name.lowercased(), value))
        }
        if !options.tags.isEmpty {
            try MetadataRules.validate(tags: options.tags)
            headers.append(HTTPHeader(dialect.taggingHeader, PercentEncoding.queryString(options.tags.map { QueryParameter($0.key, $0.value) })))
        }
        if let value = options.serverSideEncryption, !value.isEmpty {
            headers.append(HTTPHeader(dialect.sseHeader, value))
            if let key = options.kmsKeyID, !key.isEmpty {
                headers.append(HTTPHeader(configuration.provider == .s3 ? "x-amz-server-side-encryption-aws-kms-key-id"
                                          : "x-oss-server-side-encryption-key-id", key))
            }
        }
        return headers
    }

    public func putObject(bucket: String, key: String, body: Data, options: ObjectWriteOptions,
                          progress: TransferProgressHandler?) async throws -> PutResult {
        try Self.validateKey(key)
        let response = try await execute(Operation(method: "PUT", bucket: bucket, key: key,
                                                   headers: try writeHeaders(options, defaultContentType: true), body: body, progress: progress))
        return PutResult(eTag: response.header("etag"), versionID: ResponseDecoders.nonEmpty(response.header(dialect.versionIDHeader)))
    }

    public func deleteObject(bucket: String, key: String, versionID: String?) async throws {
        try Self.validateKey(key)
        _ = try await execute(Operation(method: "DELETE", bucket: bucket, key: key, query: versionQuery(versionID)))
    }

    public func deleteObjects(bucket: String, objects: [ObjectReference]) async throws -> DeleteResult {
        var result = DeleteResult()
        let representable = objects.filter { XMLWriter.isRepresentable($0.key) && !$0.key.isEmpty }
        let individual = objects.filter { !XMLWriter.isRepresentable($0.key) && !$0.key.isEmpty }
        var start = 0
        while start < representable.count {
            try Task.checkCancellation()
            let batch = Array(representable[start..<min(start + 1000, representable.count)])
            start += batch.count
            var writer = XMLWriter()
            writer.open("Delete")
            writer.element("Quiet", "true")
            for object in batch {
                writer.open("Object")
                writer.element("Key", object.key)
                if let version = object.versionID { writer.element("VersionId", version) }
                writer.close("Object")
            }
            writer.close("Delete")
            let response = try await execute(Operation(method: "POST", bucket: bucket, query: [QueryParameter("delete")],
                                                       headers: [HTTPHeader("Content-Type", "application/xml")], body: writer.data,
                                                       contentMD5: true))
            let decoded = response.body.isEmpty ? DeleteResult() : ResponseDecoders.deleteResult(try xml(response))
            // Only trust failures that refer to keys of this batch.
            let batchKeys = Set(batch.map(\.key))
            let failures = decoded.failures.filter { batchKeys.contains($0.key) }
            let failedKeys = Set(failures.map(\.key))
            result.failures.append(contentsOf: failures)
            result.deleted.append(contentsOf: batch.filter { !failedKeys.contains($0.key) })
        }
        for object in individual {
            try Task.checkCancellation()
            do {
                try await deleteObject(bucket: bucket, key: object.key, versionID: object.versionID)
                result.deleted.append(object)
            } catch let error as StorageError where !error.isCancellation {
                result.failures.append(DeleteResult.Failure(key: object.key, versionID: object.versionID, code: error.code ?? "Error",
                                                            message: error.message))
            }
        }
        return result
    }

    func copySourceValue(bucket: String, key: String, versionID: String?) -> String {
        var value = "/" + bucket + "/" + PercentEncoding.encodePath(key)
        if let versionID, !versionID.isEmpty { value += "?versionId=" + PercentEncoding.encodeQueryComponent(versionID) }
        return value
    }

    public func copyObject(_ request: CopyObjectRequest) async throws -> PutResult {
        try Self.validateKey(request.sourceKey)
        try Self.validateKey(request.destinationKey)
        var headers = [HTTPHeader(dialect.copySourceHeader, copySourceValue(bucket: request.sourceBucket, key: request.sourceKey,
                                                                             versionID: request.sourceVersionID)),
                       HTTPHeader(dialect.metadataDirectiveHeader, request.directive.rawValue)]
        switch request.directive {
        case .replace:
            headers += try writeHeaders(request.options, defaultContentType: false)
        case .copy:
            if let storageClass = request.options.storageClass, !storageClass.isEmpty {
                headers.append(HTTPHeader(dialect.storageClassHeader, storageClass))
            }
        }
        let response = try await execute(Operation(method: "PUT", bucket: request.destinationBucket, key: request.destinationKey,
                                                   headers: headers, mayReturnErrorIn200: true))
        let root = response.body.isEmpty ? nil : try? xml(response)
        return PutResult(eTag: root?.childText("ETag") ?? response.header("etag"),
                         versionID: ResponseDecoders.nonEmpty(response.header(dialect.versionIDHeader)))
    }

    public func getObjectTags(bucket: String, key: String, versionID: String?) async throws -> [ObjectTag] {
        try Self.validateKey(key)
        let response = try await execute(Operation(method: "GET", bucket: bucket, key: key,
                                                   query: [QueryParameter("tagging")] + versionQuery(versionID)))
        return ResponseDecoders.tags(try xml(response))
    }

    public func putObjectTags(bucket: String, key: String, versionID: String?, tags: [ObjectTag]) async throws {
        try Self.validateKey(key)
        let query = [QueryParameter("tagging")] + versionQuery(versionID)
        guard !tags.isEmpty else {
            _ = try await execute(Operation(method: "DELETE", bucket: bucket, key: key, query: query))
            return
        }
        try MetadataRules.validate(tags: tags)
        var writer = XMLWriter()
        writer.open("Tagging")
        writer.open("TagSet")
        for tag in tags {
            writer.open("Tag")
            writer.element("Key", tag.key)
            writer.element("Value", tag.value)
            writer.close("Tag")
        }
        writer.close("TagSet")
        writer.close("Tagging")
        _ = try await execute(Operation(method: "PUT", bucket: bucket, key: key, query: query,
                                        headers: [HTTPHeader("Content-Type", "application/xml")], body: writer.data, contentMD5: true))
    }

    // MARK: Multipart

    public func createMultipartUpload(bucket: String, key: String, options: ObjectWriteOptions) async throws -> String {
        try Self.validateKey(key)
        let response = try await execute(Operation(method: "POST", bucket: bucket, key: key, query: [QueryParameter("uploads")],
                                                   headers: try writeHeaders(options, defaultContentType: true)))
        guard let uploadID = ResponseDecoders.nonEmpty(try xml(response).childText("UploadId")) else {
            throw StorageError.invalidResponse("The service did not return an upload ID.")
        }
        return uploadID
    }

    static func validatePartNumber(_ partNumber: Int) throws {
        guard (1...10_000).contains(partNumber) else { throw StorageError.invalidRequest("Part numbers must be between 1 and 10,000.") }
    }

    public func uploadPart(bucket: String, key: String, uploadID: String, partNumber: Int, body: Data,
                           progress: TransferProgressHandler?) async throws -> UploadedPart {
        try Self.validatePartNumber(partNumber)
        let response = try await execute(Operation(method: "PUT", bucket: bucket, key: key,
                                                   query: [QueryParameter("partNumber", String(partNumber)), QueryParameter("uploadId", uploadID)],
                                                   body: body, progress: progress))
        guard let eTag = ResponseDecoders.nonEmpty(response.header("etag")) else {
            throw StorageError.invalidResponse("The service did not return an ETag for part \(partNumber).")
        }
        return UploadedPart(partNumber: partNumber, eTag: eTag, size: Int64(body.count))
    }

    public func uploadPartCopy(bucket: String, key: String, uploadID: String, partNumber: Int, sourceBucket: String,
                               sourceKey: String, sourceVersionID: String?, range: ByteRange) async throws -> UploadedPart {
        try Self.validatePartNumber(partNumber)
        let headers = [HTTPHeader(dialect.copySourceHeader, copySourceValue(bucket: sourceBucket, key: sourceKey, versionID: sourceVersionID)),
                       HTTPHeader(dialect.copySourceRangeHeader, range.headerValue)]
        let response = try await execute(Operation(method: "PUT", bucket: bucket, key: key,
                                                   query: [QueryParameter("partNumber", String(partNumber)), QueryParameter("uploadId", uploadID)],
                                                   headers: headers, mayReturnErrorIn200: true))
        guard let eTag = ResponseDecoders.nonEmpty(try xml(response).childText("ETag")) else {
            throw StorageError.invalidResponse("The service did not return an ETag for copied part \(partNumber).")
        }
        return UploadedPart(partNumber: partNumber, eTag: eTag, size: range.length)
    }

    public func completeMultipartUpload(bucket: String, key: String, uploadID: String, parts: [UploadedPart]) async throws -> PutResult {
        guard !parts.isEmpty else { throw StorageError.invalidRequest("A multipart upload needs at least one part.") }
        var writer = XMLWriter()
        writer.open("CompleteMultipartUpload")
        for part in parts.sorted(by: { $0.partNumber < $1.partNumber }) {
            writer.open("Part")
            writer.element("PartNumber", String(part.partNumber))
            writer.element("ETag", part.eTag)
            writer.close("Part")
        }
        writer.close("CompleteMultipartUpload")
        let response = try await execute(Operation(method: "POST", bucket: bucket, key: key, query: [QueryParameter("uploadId", uploadID)],
                                                   headers: [HTTPHeader("Content-Type", "application/xml")], body: writer.data,
                                                   mayReturnErrorIn200: true))
        let root = response.body.isEmpty ? nil : try? xml(response)
        return PutResult(eTag: root?.childText("ETag") ?? response.header("etag"),
                         versionID: ResponseDecoders.nonEmpty(response.header(dialect.versionIDHeader)))
    }

    public func abortMultipartUpload(bucket: String, key: String, uploadID: String) async throws {
        // Aborting an upload that no longer exists is a success.
        _ = try await execute(Operation(method: "DELETE", bucket: bucket, key: key, query: [QueryParameter("uploadId", uploadID)],
                                        acceptedStatuses: [404]))
    }

    public func listParts(bucket: String, key: String, uploadID: String) async throws -> [UploadedPart] {
        var parts: [UploadedPart] = []
        var marker: Int?
        for _ in 0..<20 {
            var query = [QueryParameter("uploadId", uploadID), QueryParameter("max-parts", "1000")]
            if let marker { query.append(QueryParameter("part-number-marker", String(marker))) }
            let response = try await execute(Operation(method: "GET", bucket: bucket, key: key, query: query))
            let page = ResponseDecoders.parts(try xml(response))
            parts.append(contentsOf: page.parts)
            guard let next = page.nextMarker, next != marker else { break }
            marker = next
        }
        return parts
    }

    // MARK: Bucket settings

    public func bucketSetting(_ kind: BucketSettingKind, bucket: String) async throws -> BucketSettingDocument {
        let response: HTTPResponse
        do {
            response = try await execute(Operation(method: "GET", bucket: bucket, query: [QueryParameter(kind.subresource)]))
        } catch let error as StorageError where error.kind == .service {
            if kind.notConfiguredCodes.contains(error.code ?? "") || (error.statusCode == 404 && error.code != "NoSuchBucket") {
                return BucketSettingDocument(kind: kind, state: .notConfigured)
            }
            if error.statusCode == 501 || error.code == "NotImplemented" {
                return BucketSettingDocument(kind: kind, state: .unsupported, message: "This service does not support \(kind.title.lowercased()).")
            }
            return BucketSettingDocument(kind: kind, state: .failed, message: error.description)
        }
        if kind == .policy {
            let raw = BucketSettingParsers.prettyJSON(response.body)
            return BucketSettingDocument(kind: kind, state: raw.isEmpty ? .notConfigured : .configured,
                                         items: BucketSettingParsers.policy(response.body), raw: raw)
        }
        let root = try xml(response)
        let items: [SettingItem]
        var state = BucketSettingDocument.State.configured
        switch kind {
        case .versioning:
            let (status, parsed) = BucketSettingParsers.versioning(root)
            items = parsed
            if status == .unversioned { state = .notConfigured }
        case .lifecycle: items = BucketSettingParsers.lifecycle(root)
        case .cors: items = BucketSettingParsers.cors(root)
        case .acl: items = dialect.parseACL(root)
        case .encryption: items = BucketSettingParsers.encryption(root)
        case .policy: items = []
        }
        if kind != .versioning, kind != .acl, items.isEmpty { state = .notConfigured }
        return BucketSettingDocument(kind: kind, state: state, items: items, raw: XMLWriter.prettyPrinted(root))
    }

    public func versioningStatus(bucket: String) async throws -> VersioningStatus {
        let response = try await execute(Operation(method: "GET", bucket: bucket, query: [QueryParameter("versioning")]))
        return BucketSettingParsers.versioning(try xml(response)).0
    }

    public func setVersioning(bucket: String, enabled: Bool) async throws {
        var writer = XMLWriter()
        writer.open("VersioningConfiguration", attributes: configuration.provider == .s3 ? ["xmlns": "http://s3.amazonaws.com/doc/2006-03-01/"] : [:])
        writer.element("Status", enabled ? "Enabled" : "Suspended")
        writer.close("VersioningConfiguration")
        _ = try await execute(Operation(method: "PUT", bucket: bucket, query: [QueryParameter("versioning")],
                                        headers: [HTTPHeader("Content-Type", "application/xml")], body: writer.data, contentMD5: true))
    }
}

/// Validation of user-supplied metadata and tags (also enforced in the UI for friendlier messages).
public enum MetadataRules {
    /// S3/OSS tag character set: Unicode letters and digits, spaces and `+ - = . _ : / @`.
    public static func isValidTagText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == " "
                || "+-=._:/@".unicodeScalars.contains(scalar)
        }
    }

    public static func validate(key: String, value: String) throws {
        guard !key.isEmpty, key.utf8.count <= 128,
              key.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ".") }) else {
            throw StorageError.invalidRequest("Metadata names may contain only letters, digits, “-”, “_” and “.” (got “\(key)”).")
        }
        guard value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }) else {
            throw StorageError.invalidRequest("Metadata value for “\(key)” must be printable ASCII.")
        }
        guard value.utf8.count <= 2048 else { throw StorageError.invalidRequest("Metadata value for “\(key)” is too long.") }
    }

    public static func validate(tags: [ObjectTag]) throws {
        guard tags.count <= 10 else { throw StorageError.invalidRequest("Objects can have at most 10 tags.") }
        guard Set(tags.map(\.key)).count == tags.count else { throw StorageError.invalidRequest("Tag keys must be unique.") }
        for tag in tags {
            guard !tag.key.isEmpty, tag.key.count <= 128, tag.value.count <= 256 else {
                throw StorageError.invalidRequest("Tag keys must be 1–128 characters and values at most 256 characters.")
            }
            guard isValidTagText(tag.key), isValidTagText(tag.value) else {
                throw StorageError.invalidRequest("Tags may contain only letters, digits, spaces and + - = . _ : / @ (got “\(tag.key)=\(tag.value)”).")
            }
        }
    }
}
