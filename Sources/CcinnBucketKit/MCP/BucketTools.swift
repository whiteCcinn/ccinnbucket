import Foundation
import StorageKit

/// The tool catalog (schemas + required access) and the tool implementations over `ObjectStorage`.
enum BucketTools {
    struct Spec: Sendable {
        let tool: MCPTool
        let access: MCPAccess
        let arguments: Set<String>
    }

    struct Outcome: Sendable {
        var payload: [String: JSONValue]
        var items: Int?
    }

    // MARK: Schema helpers

    private static func property(_ type: String, _ description: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type), "description": .string(description)]
        for (key, value) in extra { object[key] = value }
        return .object(object)
    }

    private static let connection = property("string", "Connection (account) name or id from list_connections. Optional when only one is enabled.")

    private static func schema(_ properties: [String: JSONValue], required: [String] = [], connection includeConnection: Bool = true) -> JSONValue {
        var all = properties
        if includeConnection { all["connection"] = connection }
        return .object([
            "type": .string("object"),
            "properties": .object(all),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func spec(_ name: String, _ title: String, _ description: String, access: MCPAccess, destructive: Bool = false,
                             idempotent: Bool = true, properties: [String: JSONValue] = [:], required: [String] = [],
                             includeConnection: Bool = true) -> Spec {
        let tool = MCPTool(name: name, title: title, description: description,
                           inputSchema: schema(properties, required: required, connection: includeConnection),
                           readOnly: access == .readOnly, destructive: destructive, idempotent: idempotent)
        return Spec(tool: tool, access: access, arguments: Set(properties.keys).union(includeConnection ? ["connection"] : []))
    }

    private static let bucket = property("string", "Bucket name.")
    private static let key = property("string", "Full object key, e.g. \"photos/2024/a.jpg\".")
    private static let versionID = property("string", "Optional version id (versioned buckets).")
    private static let maxKeys = property("integer", "Maximum entries to return (default 200, at most 1000).",
                                          extra: ["minimum": .int(1), "maximum": .int(1000)])

    static let all: [Spec] = [
        spec("list_connections", "List connections", "Lists the storage accounts the user enabled for AI access (no secrets).",
             access: .readOnly, includeConnection: false),
        spec("list_buckets", "List buckets", "Lists the buckets of a connection with creation date and region.", access: .readOnly),
        spec("list_objects", "List objects",
             "Lists objects and folders (common prefixes) under a prefix, one page at a time. Use delimiter \"/\" (default) to list a folder, an empty delimiter to list recursively, and continuation_token from the previous page to continue.",
             access: .readOnly, properties: [
                 "bucket": bucket,
                 "prefix": property("string", "Key prefix, usually a folder ending in \"/\" (default: bucket root)."),
                 "delimiter": property("string", "Folder delimiter (default \"/\"; use \"\" for a recursive listing)."),
                 "continuation_token": property("string", "Token from the previous page's nextContinuationToken."),
                 "max_keys": maxKeys,
             ], required: ["bucket"]),
        spec("head_object", "Object metadata", "Returns an object's size, ETag, dates, content type, storage class, encryption and user metadata.",
             access: .readOnly, properties: ["bucket": bucket, "key": key, "version_id": versionID], required: ["bucket", "key"]),
        spec("read_object_text", "Read text object",
             "Reads part of a text or JSON object (UTF-8). Binary objects are refused. Use offset and max_bytes to page through large files.",
             access: .readOnly, properties: [
                 "bucket": bucket, "key": key, "version_id": versionID,
                 "offset": property("integer", "Byte offset to start reading (default 0).", extra: ["minimum": .int(0)]),
                 "max_bytes": property("integer", "Bytes to read (default 65536, at most 262144).", extra: ["minimum": .int(1), "maximum": .int(262_144)]),
             ], required: ["bucket", "key"]),
        spec("object_versions", "List object versions", "Lists versions and delete markers under a prefix (versioned buckets).",
             access: .readOnly, properties: [
                 "bucket": bucket, "prefix": property("string", "Key prefix (default: whole bucket)."),
                 "key_marker": property("string", "nextKeyMarker from the previous page."),
                 "version_id_marker": property("string", "nextVersionIdMarker from the previous page."),
                 "max_keys": maxKeys,
             ], required: ["bucket"]),
        spec("put_text_object", "Write text object", "Creates or replaces an object with UTF-8 text (at most 1 MiB). Requires read-write access.",
             access: .readWrite, destructive: true, properties: [
                 "bucket": bucket, "key": key, "text": property("string", "The full object content."),
                 "content_type": property("string", "Content-Type (default text/plain; charset=utf-8)."),
             ], required: ["bucket", "key", "text"]),
        spec("delete_objects", "Delete objects", "Deletes up to 100 objects by exact key (no prefixes or wildcards). Requires read-write access.",
             access: .readWrite, destructive: true, properties: [
                 "bucket": bucket,
                 "keys": property("array", "Exact keys to delete (1–100).", extra: ["items": .object(["type": .string("string")]),
                                                                              "minItems": .int(1), "maxItems": .int(100)]),
             ], required: ["bucket", "keys"]),
        spec("copy_object", "Copy object", "Copies one object server-side (multipart copy for large objects). Requires read-write access.",
             access: .readWrite, destructive: true, properties: [
                 "source_bucket": property("string", "Source bucket."), "source_key": property("string", "Source key."),
                 "source_version_id": property("string", "Optional source version id."),
                 "destination_bucket": property("string", "Destination bucket."), "destination_key": property("string", "Destination key."),
             ], required: ["source_bucket", "source_key", "destination_bucket", "destination_key"]),
        spec("presign_url", "Create presigned link",
             "Creates a time-limited download link that works outside the app (treated as a write-level permission). Requires read-write access.",
             access: .readWrite, destructive: false, idempotent: false, properties: [
                 "bucket": bucket, "key": key, "version_id": versionID,
                 "expires_seconds": property("integer", "Lifetime in seconds (default 3600, at most 604800).",
                                             extra: ["minimum": .int(1), "maximum": .int(604_800)]),
             ], required: ["bucket", "key"]),
    ]

    // MARK: Implementations

    static func run(_ name: String, args: ToolArguments, storage: any ObjectStorage) async throws -> Outcome {
        switch name {
        case "list_buckets": return try await listBuckets(storage)
        case "list_objects": return try await listObjects(args, storage)
        case "head_object": return try await headObject(args, storage)
        case "read_object_text": return try await readText(args, storage)
        case "object_versions": return try await versions(args, storage)
        case "put_text_object": return try await putText(args, storage)
        case "delete_objects": return try await delete(args, storage)
        case "copy_object": return try await copy(args, storage)
        case "presign_url": return try await presign(args, storage)
        default: throw ToolError("Unknown tool \(name)")
        }
    }

    private static func listBuckets(_ storage: any ObjectStorage) async throws -> Outcome {
        let buckets = try await storage.listBuckets()
        let shown = buckets.prefix(MCPLimits.maximumItems)
        return Outcome(payload: [
            "buckets": .array(shown.map { .object(["name": .string($0.name), "creationDate": .from($0.creationDate), "region": .from($0.region)]) }),
            "count": .from(buckets.count),
            "truncated": .bool(buckets.count > shown.count),
        ], items: shown.count)
    }

    /// Opaque continuation tokens: `v2:<token>` or `v1:<marker>`.
    static func encodeToken(_ token: ListToken?) -> JSONValue {
        switch token {
        case let .continuation(value)?: .string("v2:" + value)
        case let .marker(value)?: .string("v1:" + value)
        case nil: .null
        }
    }

    static func decodeToken(_ text: String?) throws -> ListToken? {
        guard let text, !text.isEmpty else { return nil }
        if text.hasPrefix("v2:") { return .continuation(String(text.dropFirst(3))) }
        if text.hasPrefix("v1:") { return .marker(String(text.dropFirst(3))) }
        throw ToolError("Invalid continuation_token; pass the nextContinuationToken value from the previous result unchanged.")
    }

    /// Whether a payload fits the result limit (with headroom for the JSON-RPC envelope).
    static func fits(_ payload: [String: JSONValue]) -> Bool {
        JSONValue.object(payload).encoded().count <= MCPLimits.maximumResultBytes - 1_024
    }

    private static func listObjects(_ args: ToolArguments, _ storage: any ObjectStorage) async throws -> Outcome {
        let bucket = try args.requiredString("bucket")
        let prefix = try args.string("prefix") ?? ""
        let delimiter = try args.string("delimiter") ?? "/"
        let requested = try args.int("max_keys", default: MCPLimits.defaultItems, range: 1...MCPLimits.maximumItems)
        let token = try decodeToken(args.string("continuation_token"))
        var limit = requested
        while true {
            // Ask the server for fewer keys rather than cutting a page: its continuation token stays exact.
            let page = try await storage.listObjects(ListObjectsRequest(bucket: bucket, prefix: prefix, delimiter: delimiter.isEmpty ? nil : delimiter,
                                                                        token: token, maxKeys: limit))
            var payload: [String: JSONValue] = [
                "bucket": .string(bucket),
                "prefix": .string(prefix),
                "objects": .array(page.objects.map { object in
                    .object(["key": .string(object.key), "size": .int(object.size), "lastModified": .from(object.lastModified),
                             "eTag": .from(object.eTag), "storageClass": .from(object.storageClass)])
                }),
                "commonPrefixes": .array(page.commonPrefixes.map(JSONValue.string)),
                "isTruncated": .bool(page.isTruncated),
                "nextContinuationToken": page.isTruncated ? encodeToken(page.nextToken) : .null,
            ]
            if limit < requested { payload["pageSizeReduced"] = .bool(true) }
            if fits(payload) || limit == 1 { return Outcome(payload: payload, items: page.objects.count + page.commonPrefixes.count) }
            limit = max(1, limit / 2)
        }
    }

    private static func headObject(_ args: ToolArguments, _ storage: any ObjectStorage) async throws -> Outcome {
        let metadata = try await storage.headObject(bucket: args.requiredString("bucket"), key: args.requiredString("key"),
                                                    versionID: args.string("version_id"))
        return Outcome(payload: [
            "key": .string(metadata.key), "size": .int(metadata.size), "eTag": .from(metadata.eTag),
            "lastModified": .from(metadata.lastModified), "contentType": .from(metadata.contentType),
            "cacheControl": .from(metadata.cacheControl), "contentDisposition": .from(metadata.contentDisposition),
            "contentEncoding": .from(metadata.contentEncoding), "storageClass": .from(metadata.storageClass),
            "versionId": .from(metadata.versionID), "serverSideEncryption": .from(metadata.serverSideEncryption),
            "tagCount": metadata.tagCount.map { .from($0) } ?? .null,
            "userMetadata": .object(metadata.userMetadata.mapValues(JSONValue.string)),
        ], items: 1)
    }

    /// Content types that are certainly not text.
    static func isBinaryContentType(_ type: String?, key: String) -> Bool {
        guard let type = type?.lowercased().split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces) }), !type.isEmpty else { return false }
        if type.hasPrefix("text/") || type.hasSuffix("+json") || type.hasSuffix("+xml") { return false }
        if ["application/json", "application/xml", "application/javascript", "application/x-ndjson", "application/yaml",
            "application/x-yaml", "application/toml", "application/sql", "application/x-sh"].contains(type) { return false }
        if type == "application/octet-stream" || type == "binary/octet-stream" {
            let textual = PreviewPlan.make(key: key, contentType: nil, size: 1).kind
            return textual != .text && textual != .json
        }
        return true
    }

    private static func readText(_ args: ToolArguments, _ storage: any ObjectStorage) async throws -> Outcome {
        let bucket = try args.requiredString("bucket")
        let key = try args.requiredString("key")
        let versionID = try args.string("version_id")
        let offset = Int64(try args.int("offset", default: 0, range: 0...Int.max))
        let maxBytes = Int64(try args.int("max_bytes", default: MCPLimits.defaultTextBytes, range: 1...MCPLimits.maximumTextBytes))
        let metadata = try await storage.headObject(bucket: bucket, key: key, versionID: versionID)
        if isBinaryContentType(metadata.contentType, key: key) {
            throw ToolError("“\(key)” is not text (Content-Type \(metadata.contentType ?? "unknown")); use head_object for its metadata.")
        }
        guard metadata.size > 0 else {
            return Outcome(payload: ["bucket": .string(bucket), "key": .string(key), "offset": .int(0), "bytesRead": .int(0),
                                     "totalSize": .int(0), "truncated": .bool(false), "contentType": .from(metadata.contentType), "text": .string("")], items: 0)
        }
        guard offset < metadata.size else { throw ToolError("offset \(offset) is beyond the end of the object (\(metadata.size) bytes).") }
        // Overflow-safe end of range: never compute offset + maxBytes when it could exceed the size.
        let last = (metadata.size - offset > maxBytes ? offset + maxBytes : metadata.size) - 1
        guard let range = ByteRange(first: offset, last: last) else { throw ToolError("Invalid range.") }
        let data = try await storage.getObject(bucket: bucket, key: key, versionID: versionID, range: range, maxBytes: Int(range.length) + 1).data
        guard !data.contains(0), let decoded = decodeUTF8(data, droppingLeadingContinuation: offset > 0) else {
            throw ToolError("“\(key)” is not text (binary or not UTF-8); use head_object for its metadata.")
        }
        var text = decoded.text
        func payload(_ text: String) -> [String: JSONValue] {
            // bytesRead counts exactly the bytes consumed, so offset + bytesRead is where the next read continues.
            let bytesRead = Int64(decoded.skippedLeadingBytes + text.utf8.count)
            return ["bucket": .string(bucket), "key": .string(key), "offset": .int(offset), "bytesRead": .int(bytesRead),
                    "totalSize": .int(metadata.size), "truncated": .bool(offset + bytesRead < metadata.size),
                    "contentType": .from(metadata.contentType), "text": .string(text)]
        }
        var result = payload(text)
        if !fits(result) {
            // JSON escaping can grow text a lot; return fewer characters and say so (bytesRead stays exact).
            var low = 0
            var high = text.count
            while low < high {
                let mid = (low + high + 1) / 2
                if fits(payload(String(text.prefix(mid)))) { low = mid } else { high = mid - 1 }
            }
            text = String(text.prefix(low))
            result = payload(text)
            result["resultShortened"] = .bool(true)
        }
        return Outcome(payload: result, items: 1)
    }

    /// Decodes UTF-8, tolerating a character split at either end of the range.
    static func decodeUTF8(_ data: Data, droppingLeadingContinuation: Bool) -> (text: String, skippedLeadingBytes: Int)? {
        var slice = data[...]
        var skipped = 0
        if droppingLeadingContinuation {
            while let first = slice.first, first & 0xC0 == 0x80, skipped < 3 {
                slice = slice.dropFirst()
                skipped += 1
            }
        }
        for trim in 0...3 where slice.count >= trim {
            if let text = String(data: Data(slice.dropLast(trim)), encoding: .utf8) { return (text, skipped) }
        }
        return nil
    }

    private static func versions(_ args: ToolArguments, _ storage: any ObjectStorage) async throws -> Outcome {
        let bucket = try args.requiredString("bucket")
        let requested = try args.int("max_keys", default: MCPLimits.defaultItems, range: 1...MCPLimits.maximumItems)
        let prefix = try args.string("prefix") ?? ""
        let keyMarker = try args.string("key_marker")
        let versionMarker = try args.string("version_id_marker")
        var limit = requested
        while true {
            let page = try await storage.listObjectVersions(VersionListRequest(bucket: bucket, prefix: prefix, delimiter: nil, keyMarker: keyMarker,
                                                                               versionIDMarker: versionMarker, maxKeys: limit))
            var payload: [String: JSONValue] = [
                "bucket": .string(bucket),
                "versions": .array(page.versions.map { version in
                    .object(["key": .string(version.key), "versionId": .string(version.versionID), "isLatest": .bool(version.isLatest),
                             "isDeleteMarker": .bool(version.isDeleteMarker), "size": .int(version.size), "lastModified": .from(version.lastModified),
                             "eTag": .from(version.eTag)])
                }),
                "isTruncated": .bool(page.isTruncated),
                "nextKeyMarker": .from(page.nextKeyMarker),
                "nextVersionIdMarker": .from(page.nextVersionIDMarker),
            ]
            if limit < requested { payload["pageSizeReduced"] = .bool(true) }
            if fits(payload) || limit == 1 { return Outcome(payload: payload, items: page.versions.count) }
            limit = max(1, limit / 2)
        }
    }

    private static func putText(_ args: ToolArguments, _ storage: any ObjectStorage) async throws -> Outcome {
        let bucket = try args.requiredString("bucket")
        let key = try args.requiredString("key")
        guard let text = try args.string("text") else { throw ToolError("“text” is required.") }
        let body = Data(text.utf8)
        guard body.count <= MCPLimits.maximumPutBytes else { throw ToolError("text is larger than 1 MiB.") }
        let contentType = try args.string("content_type") ?? "text/plain; charset=utf-8"
        let result = try await storage.putObject(bucket: bucket, key: key, body: body, options: ObjectWriteOptions(contentType: contentType), progress: nil)
        return Outcome(payload: ["bucket": .string(bucket), "key": .string(key), "size": .int(Int64(body.count)), "eTag": .from(result.eTag),
                                 "versionId": .from(result.versionID)], items: 1)
    }

    private static func delete(_ args: ToolArguments, _ storage: any ObjectStorage) async throws -> Outcome {
        let bucket = try args.requiredString("bucket")
        let keys = try args.stringArray("keys")
        guard (1...MCPLimits.maximumDeleteKeys).contains(keys.count) else { throw ToolError("Pass between 1 and \(MCPLimits.maximumDeleteKeys) keys.") }
        let result = try await storage.deleteObjects(bucket: bucket, objects: Set(keys).sorted().map { ObjectReference(key: $0) })
        return Outcome(payload: [
            "bucket": .string(bucket),
            "deleted": .array(result.deleted.map { .string($0.key) }),
            "errors": .array(result.failures.map { .object(["key": .string($0.key), "code": .string($0.code), "message": .string($0.message)]) }),
        ], items: result.deleted.count)
    }

    private static func copy(_ args: ToolArguments, _ storage: any ObjectStorage) async throws -> Outcome {
        let request = CopyObjectRequest(sourceBucket: try args.requiredString("source_bucket"), sourceKey: try args.requiredString("source_key"),
                                        sourceVersionID: try args.string("source_version_id"),
                                        destinationBucket: try args.requiredString("destination_bucket"),
                                        destinationKey: try args.requiredString("destination_key"))
        let result = try await ServerSideCopier(storage: storage).copy(request)
        return Outcome(payload: ["destinationBucket": .string(request.destinationBucket), "destinationKey": .string(request.destinationKey),
                                 "eTag": .from(result.eTag), "versionId": .from(result.versionID)], items: 1)
    }

    private static func presign(_ args: ToolArguments, _ storage: any ObjectStorage) async throws -> Outcome {
        let expires = try args.strictInt("expires_seconds", default: 3_600, range: 1...storage.capabilities.maxPresignExpiry)
        let bucket = try args.requiredString("bucket")
        let key = try args.requiredString("key")
        let url = try await storage.presignedURL(bucket: bucket, key: key, versionID: args.string("version_id"), method: "GET", expires: expires,
                                                 responseContentDisposition: nil)
        return Outcome(payload: ["url": .string(url.absoluteString), "expiresAt": .from(Date().addingTimeInterval(TimeInterval(expires))),
                                 "expiresSeconds": .int(Int64(expires))], items: 1)
    }
}
