import Foundation
import StorageKit
import StorageSigning

/// Object-storage tools for AI clients. Accounts must be opted in (`mcpAccess`); effective access is capped
/// by the account's read-only flag and `--read-only`. Read-only accounts also get a `ReadOnlyStorage`, so a
/// write can never reach the service even if a check here were wrong.
public actor BucketToolHandler: MCPToolHandler {
    public typealias StorageFactory = @Sendable (StorageAccount, SigningCredentials) throws -> any ObjectStorage

    public nonisolated let serverName = "ccinnbucket"
    public nonisolated let serverTitle = "CcinnBucket"
    public nonisolated let instructions = """
        CcinnBucket gives access to object storage (Amazon S3, S3-compatible services such as MinIO or R2, and Alibaba Cloud OSS) \
        through accounts the user explicitly enabled for AI access. Call list_connections first, then list_buckets and list_objects \
        (use prefix and delimiter "/" to walk folders, and continuation_token to page). read_object_text reads text/JSON objects in \
        byte ranges. Results are bounded (at most 1,000 entries per call, 256 KiB of text) and carry "truncated": true when shortened. \
        Access is read-only unless the user granted read-write for an account; put_text_object, delete_objects, copy_object and \
        presign_url only work for such accounts.
        """

    private let accounts: [StorageAccount]
    private let credentials: @Sendable (StorageAccount) -> SigningCredentials?
    private let defaultConnection: String?
    private let forceReadOnly: Bool
    private let audit: MCPAuditLog?
    private let storageFactory: StorageFactory
    private var pool: [UUID: any ObjectStorage] = [:]

    public init(accounts: [StorageAccount], credentials: @escaping @Sendable (StorageAccount) -> SigningCredentials?,
                defaultConnection: String? = nil, forceReadOnly: Bool = false, audit: MCPAuditLog? = nil,
                storageFactory: @escaping StorageFactory = BucketToolHandler.makeStorage) {
        self.accounts = accounts
        self.credentials = credentials
        self.defaultConnection = defaultConnection
        self.forceReadOnly = forceReadOnly
        self.audit = audit
        self.storageFactory = storageFactory
    }

    /// Production storage: a real client, wrapped read-only unless the effective access allows writes.
    public static let makeStorage: StorageFactory = { account, credentials in
        let client = ObjectStorageClient(configuration: try account.storageConfiguration(), credentials: credentials, transport: URLSessionTransport())
        return account.mcpAccess == .readWrite && !account.isReadOnly ? client : ReadOnlyStorage(client)
    }

    // MARK: Access

    func effectiveAccess(_ account: StorageAccount) -> MCPAccess {
        var access = account.mcpAccess
        if access == .readWrite, account.isReadOnly || forceReadOnly { access = .readOnly }
        return access
    }

    private var enabledAccounts: [StorageAccount] { accounts.filter { effectiveAccess($0) != .disabled } }

    private func resolve(_ requested: String?) -> Result<StorageAccount, ToolError> {
        let enabled = enabledAccounts
        let names = enabled.map(\.displayName)
        let listing = names.isEmpty ? "No account is enabled for AI access; enable one in CcinnBucket (account editor → AI access via MCP)."
            : "Enabled connections: \(names.joined(separator: ", "))."
        if let wanted = (requested ?? defaultConnection)?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            let match = enabled.first { $0.displayName == wanted || $0.id.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }
                ?? enabled.first { $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame }
            guard let match else { return .failure(ToolError("No AI-enabled connection named “\(wanted)”. \(listing)")) }
            return .success(match)
        }
        if enabled.count == 1, let only = enabled.first { return .success(only) }
        return .failure(ToolError(enabled.isEmpty ? listing : "Several connections are enabled; pass \"connection\". \(listing)"))
    }

    private func storage(for account: StorageAccount) throws -> any ObjectStorage {
        if let cached = pool[account.id] { return cached }
        guard let credentials = credentials(account) else {
            throw ToolError("No secret access key is stored for “\(account.displayName)”. Open CcinnBucket and save the account's secret key.")
        }
        var effective = account
        effective.mcpAccess = effectiveAccess(account)
        let storage = try storageFactory(effective, credentials)
        pool[account.id] = storage
        return storage
    }

    // MARK: MCPToolHandler

    public func tools() -> [MCPTool] {
        let writable = enabledAccounts.contains { effectiveAccess($0) == .readWrite }
        return BucketTools.all.filter { writable || $0.access == .readOnly }.map(\.tool)
    }

    public func knows(tool name: String) -> Bool { BucketTools.all.contains { $0.tool.name == name } }

    public func call(tool name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        let started = Date()
        var connectionName: String?
        var items: Int?
        let result: MCPToolResult
        do {
            guard let spec = BucketTools.all.first(where: { $0.tool.name == name }) else { throw ToolError("Unknown tool \(name)") }
            let args = try ToolArguments(arguments, allowed: spec.arguments)
            if spec.tool.name == "list_connections" {
                let value = listConnections()
                items = enabledAccounts.count
                result = .success(value)
            } else {
                let account = try resolve(args.string("connection")).get()
                connectionName = account.displayName
                if spec.access == .readWrite, effectiveAccess(account) != .readWrite {
                    throw ToolError("“\(account.displayName)” allows read-only AI access; \(name) needs read-write access (CcinnBucket → account editor → AI access via MCP).")
                }
                let storage = try storage(for: account)
                let outcome = try await Self.withTimeout(MCPLimits.callTimeout) { [args] in
                    try await BucketTools.run(name, args: args, storage: storage)
                }
                items = outcome.items
                result = .success(MCPLimits.fit(outcome.payload))
            }
        } catch let error as ToolError {
            result = .failure(error.message)
        } catch is CancellationError {
            result = .failure("The request was cancelled.")
        } catch {
            let wrapped = StorageError.wrap(error)
            result = .failure(wrapped.isCancellation ? "The request was cancelled." : wrapped.description)
        }
        if let audit {
            var errorText: String?
            if case let .failure(message) = result { errorText = message }
            await audit.record(tool: name, connection: connectionName, arguments: arguments, duration: Date().timeIntervalSince(started),
                               items: items, error: errorText)
        }
        return result
    }

    private func listConnections() -> JSONValue {
        .object(["connections": .array(enabledAccounts.map { account in
            .object([
                "name": .string(account.displayName),
                "id": .string(account.id.uuidString),
                "provider": .string(account.kind.displayName),
                "endpoint": .string(account.effectiveEndpointDescription),
                "region": .string(account.region),
                "access": .string(effectiveAccess(account).rawValue),
                "defaultBucket": account.defaultBucket.isEmpty ? .null : .string(account.defaultBucket),
            ])
        })])
    }

    /// Runs `body` with a deadline; the body is cancelled when the deadline passes.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ToolError("The request timed out after \(Int(seconds)) s.")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ToolError("No result.") }
            return first
        }
    }
}

struct ToolError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Typed, validated access to tool arguments (unknown keys are rejected).
struct ToolArguments: Sendable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue], allowed: Set<String>) throws {
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ToolError("Unknown argument “\(unknown)”. Allowed: \(allowed.sorted().joined(separator: ", ")).")
        }
        self.values = values
    }

    func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case let .string(value)?: return value
        default: throw ToolError("“\(key)” must be a string.")
        }
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = try string(key), !value.isEmpty else { throw ToolError("“\(key)” is required.") }
        return value
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        switch values[key] {
        case nil, .null?: return fallback
        case let value?:
            guard let number = value.intValue else { throw ToolError("“\(key)” must be an integer.") }
            return Int(min(max(number, Int64(range.lowerBound)), Int64(range.upperBound)))
        }
    }

    func strictInt(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        switch values[key] {
        case nil, .null?: return fallback
        case let value?:
            guard let number = value.intValue, number >= Int64(range.lowerBound), number <= Int64(range.upperBound) else {
                throw ToolError("“\(key)” must be an integer between \(range.lowerBound) and \(range.upperBound).")
            }
            return Int(number)
        }
    }

    func stringArray(_ key: String) throws -> [String] {
        guard let array = values[key]?.arrayValue else { throw ToolError("“\(key)” must be an array of strings.") }
        return try array.map { item in
            guard let text = item.stringValue, !text.isEmpty else { throw ToolError("“\(key)” must contain non-empty strings.") }
            return text
        }
    }
}

/// Appends one JSON line per tool call to `mcp-audit.jsonl` (object contents and secrets are never logged).
public actor MCPAuditLog {
    public let url: URL
    static let rotationBytes: UInt64 = 10 << 20

    public init(url: URL) {
        self.url = url
    }

    func record(tool: String, connection: String?, arguments: [String: JSONValue], duration: TimeInterval, items: Int?, error: String?) {
        var summary = arguments
        if let text = summary["text"]?.stringValue { summary["text"] = .string("<\(text.utf8.count) bytes>") }
        if let keys = summary["keys"]?.arrayValue, keys.count > 20 {
            summary["keys"] = .array(Array(keys.prefix(20)) + [.string("… \(keys.count - 20) more")])
        }
        var entry: [String: JSONValue] = [
            "time": .string(Date().formatted(.iso8601)),
            "source": .string("mcp"),
            "tool": .string(tool),
            "connection": .from(connection),
            "arguments": .object(summary),
            "durationMs": .int(Int64(max(0, min(duration, 86_400)) * 1000)),
        ]
        if let items { entry["items"] = .from(items) }
        if let error { entry["error"] = .string(String(error.prefix(2_000))) }
        append(JSONValue.object(entry).encoded() + Data("\n".utf8))
    }

    private func append(_ line: Data) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > Self.rotationBytes {
            let rotated = url.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: url, to: rotated)
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
