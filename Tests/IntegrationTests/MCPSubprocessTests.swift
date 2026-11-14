import CcinnBucketKit
import Foundation
import os
import StorageKit
import Testing

/// Drives `CcinnBucket mcp` as a subprocess over stdio against the MinIO test container.
/// The account store points at a temp folder and secrets come from the documented test-only variable.
final class MCPProcess: Sendable {
    private let process: Process
    private let input: FileHandle
    private let buffer = OSAllocatedUnfairLock(initialState: Data())
    private let lines = OSAllocatedUnfairLock<[JSONValue]>(initialState: [])

    init(binary: URL, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        self.process = process
        input = stdin.fileHandleForWriting
        let buffer = buffer
        let lines = lines
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.withLock { data in
                data.append(chunk)
                while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = data[data.startIndex..<newline]
                    if let value = try? JSONValue.parse(Data(line)) { lines.withLock { $0.append(value) } }
                    data.removeSubrange(data.startIndex...newline)
                }
            }
        }
        try process.run()
    }

    func send(_ json: String) throws {
        try input.write(contentsOf: Data((json + "\n").utf8))
    }

    func request(_ id: Int, _ method: String, _ params: String = "{}") async throws -> JSONValue {
        try send(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#)
        for _ in 0..<600 {
            if let response = lines.withLock({ $0.first { $0["id"] == .int(Int64(id)) } }) { return response }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw StorageError.invalidResponse("no MCP response for request \(id)")
    }

    func call(_ id: Int, _ tool: String, _ arguments: String) async throws -> JSONValue {
        try await request(id, "tools/call", #"{"name":"\#(tool)","arguments":\#(arguments)}"#)
    }

    var allLines: [JSONValue] { lines.withLock { $0 } }

    /// Closes stdin and waits for the process to exit.
    func finish() async -> Int32? {
        try? input.close()
        for _ in 0..<200 {
            if !process.isRunning { return process.terminationStatus }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        process.terminate()
        return nil
    }

    static func binary() -> URL? {
        if let path = ProcessInfo.processInfo.environment["CCINNBUCKET_BINARY"] { return URL(fileURLWithPath: path) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/CcinnBucket", ".build/arm64-apple-macosx/debug/CcinnBucket", ".build/out/Products/Debug/CcinnBucket",
                          ".build/x86_64-apple-macosx/debug/CcinnBucket"]
        return candidates.map { root.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

@Suite("MCP server subprocess against MinIO", .enabled(if: IT.enabled), .serialized)
struct MCPSubprocessTests {
    static func payload(_ response: JSONValue) -> JSONValue? {
        guard let text = response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue else { return nil }
        return try? JSONValue.parse(Data(text.utf8))
    }

    static func isError(_ response: JSONValue) -> Bool { response["result"]?["isError"]?.boolValue == true }

    @Test("full session: initialize, tools, listing, reading, write gating, presign, audit, clean exit")
    func session() async throws {
        let binary = try #require(MCPProcess.binary(), "build the app first (swift build) or set CCINNBUCKET_BINARY")
        let directory = try IT.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var readOnly = StorageAccount(kind: .minio, name: "Local MinIO", accessKeyID: IT.credentials.accessKeyID)
        readOnly.endpoint = IT.endpoint.description
        readOnly.mcpAccess = .readOnly
        var writable = readOnly
        writable.id = UUID()
        writable.name = "MinIO RW"
        writable.mcpAccess = .readWrite
        var hidden = readOnly
        hidden.id = UUID()
        hidden.name = "Not for AI"
        hidden.mcpAccess = .disabled
        try AccountRepository(directory: directory, secrets: InMemorySecretStore()).save([readOnly, writable, hidden])
        let secret = IT.credentials.secretAccessKey
        let secrets = #"{"Local MinIO":{"secretAccessKey":"\#(secret)"},"MinIO RW":{"secretAccessKey":"\#(secret)"},"Not for AI":{"secretAccessKey":"\#(secret)"}}"#
        let server = try MCPProcess(binary: binary, arguments: [], environment: [
            MCPLauncher.accountsDirectoryVariable: directory.path, MCPLauncher.insecureTestSecretsVariable: secrets,
        ])

        let initialize = try await server.request(1, "initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"it","version":"1"}}"#)
        #expect(initialize["result"]?["serverInfo"]?["name"]?.stringValue == "ccinnbucket")
        try server.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let tools = try await server.request(2, "tools/list")
        #expect(tools["result"]?["tools"]?.arrayValue?.count == 10)

        let connections = try #require(Self.payload(try await server.call(3, "list_connections", "{}")))
        #expect(connections["connections"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["Local MinIO", "MinIO RW"])

        let ambiguous = try await server.call(4, "list_buckets", "{}")
        #expect(Self.isError(ambiguous))
        let buckets = try #require(Self.payload(try await server.call(5, "list_buckets", #"{"connection":"Local MinIO"}"#)))
        #expect(buckets["buckets"]?.arrayValue?.contains { $0["name"]?.stringValue == "ccinn-demo" } == true)

        let special = try #require(Self.payload(try await server.call(6, "list_objects", #"{"connection":"Local MinIO","bucket":"ccinn-demo","prefix":"special/"}"#)))
        #expect(special["objects"]?.arrayValue?.compactMap { $0["key"]?.stringValue }.contains("special/a+b c~d.txt") == true)
        let bulk = try #require(Self.payload(try await server.call(7, "list_objects", #"{"connection":"Local MinIO","bucket":"ccinn-large","prefix":"bulk/","max_keys":5000}"#)))
        #expect(bulk["objects"]?.arrayValue?.count == 1_000)
        let token = try #require(bulk["nextContinuationToken"]?.stringValue)
        let next = try #require(Self.payload(try await server.call(8, "list_objects", #"{"connection":"Local MinIO","bucket":"ccinn-large","prefix":"bulk/","continuation_token":"\#(token)","max_keys":10}"#)))
        #expect(next["objects"]?.arrayValue?.first?["key"]?.stringValue == "bulk/obj-001000.txt")

        let readme = try #require(Self.payload(try await server.call(9, "read_object_text", #"{"connection":"Local MinIO","bucket":"ccinn-demo","key":"docs/README.md"}"#)))
        #expect(readme["text"]?.stringValue?.contains("CcinnBucket demo") == true)
        let unicode = try #require(Self.payload(try await server.call(10, "read_object_text", #"{"connection":"Local MinIO","bucket":"ccinn-demo","key":"unicode/日本語 フォルダ/メモ.txt"}"#)))
        #expect(unicode["text"]?.stringValue == "日本語のテキスト\n")
        #expect(Self.isError(try await server.call(11, "read_object_text", #"{"connection":"Local MinIO","bucket":"ccinn-demo","key":"photos/cover.png"}"#)))

        let key = "mcp-it/\(UUID().uuidString).txt"
        #expect(Self.isError(try await server.call(12, "put_text_object", #"{"connection":"Local MinIO","bucket":"ccinn-demo","key":"\#(key)","text":"x"}"#)))
        #expect(Self.isError(try await server.call(13, "presign_url", #"{"connection":"Local MinIO","bucket":"ccinn-demo","key":"docs/README.md"}"#)))
        #expect(!Self.isError(try await server.call(14, "put_text_object", #"{"connection":"MinIO RW","bucket":"ccinn-demo","key":"\#(key)","text":"hello from mcp"}"#)))
        let link = try #require(Self.payload(try await server.call(15, "presign_url", #"{"connection":"MinIO RW","bucket":"ccinn-demo","key":"\#(key)","expires_seconds":120}"#)))
        let url = try #require(link["url"]?.stringValue.flatMap(URL.init(string:)))
        let (body, _) = try await URLSession(configuration: .ephemeral).data(from: url)
        #expect(String(decoding: body, as: UTF8.self) == "hello from mcp")
        let deleted = try #require(Self.payload(try await server.call(16, "delete_objects", #"{"connection":"MinIO RW","bucket":"ccinn-demo","keys":["\#(key)"]}"#)))
        #expect(deleted["deleted"]?.arrayValue == [.string(key)])
        #expect(Self.isError(try await server.call(17, "list_buckets", #"{"connection":"Not for AI"}"#)))

        #expect(!server.allLines.description.contains(secret), "secrets never appear in protocol output")
        let status = await server.finish()
        #expect(status == 0)
        let audit = try String(contentsOf: directory.appendingPathComponent("mcp-audit.jsonl"), encoding: .utf8)
        #expect(audit.split(separator: "\n").count >= 15)
        #expect(!audit.contains(secret))
        #expect(!audit.contains("hello from mcp"))
    }

    @Test("--read-only caps read-write accounts")
    func readOnlyFlag() async throws {
        let binary = try #require(MCPProcess.binary())
        let directory = try IT.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var account = StorageAccount(kind: .minio, name: "Local MinIO", accessKeyID: IT.credentials.accessKeyID)
        account.endpoint = IT.endpoint.description
        account.mcpAccess = .readWrite
        try AccountRepository(directory: directory, secrets: InMemorySecretStore()).save([account])
        let server = try MCPProcess(binary: binary, arguments: ["--read-only"], environment: [
            MCPLauncher.accountsDirectoryVariable: directory.path,
            MCPLauncher.insecureTestSecretsVariable: #"{"Local MinIO":{"secretAccessKey":"\#(IT.credentials.secretAccessKey)"}}"#,
        ])
        _ = try await server.request(1, "initialize", #"{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"it","version":"1"}}"#)
        let tools = try await server.request(2, "tools/list")
        #expect(tools["result"]?["tools"]?.arrayValue?.count == 6)
        #expect(Self.isError(try await server.call(3, "delete_objects", #"{"bucket":"ccinn-demo","keys":["docs/README.md"]}"#)))
        let still = try await server.call(4, "head_object", #"{"bucket":"ccinn-demo","key":"docs/README.md"}"#)
        #expect(!Self.isError(still))
        #expect(still["result"]?["structuredContent"] == nil, "2024-11-05 clients get text content only")
        _ = await server.finish()
    }
}
