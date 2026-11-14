import CcinnBucketKit
import Foundation
import os
import StorageKit
import StorageSigning
import Testing

/// Collects every line the server writes.
final class OutputSink: Sendable {
    private let lines = OSAllocatedUnfairLock<[Data]>(initialState: [])

    var write: @Sendable (Data) -> Void { { [lines] data in lines.withLock { $0.append(data) } } }

    var messages: [JSONValue] { lines.withLock { $0 }.compactMap { try? JSONValue.parse($0) } }

    func response(id: Int) -> JSONValue? { messages.first { $0["id"] == .int(Int64(id)) } }
}

@Suite("MCP: framing and JSON")
struct MCPFramingTests {
    @Test("lines split across chunks, CRLF, empty lines, oversized lines")
    func framing() {
        var buffer = MCPLineBuffer(maximumLineBytes: 16)
        #expect(buffer.append(Data("{\"a\":".utf8)).isEmpty)
        #expect(buffer.append(Data("1}\r\n\n{\"b\":2}\n".utf8)) == [.message(Data("{\"a\":1}".utf8)), .message(Data("{\"b\":2}".utf8))])
        let oversized = buffer.append(Data(String(repeating: "x", count: 40).utf8))
        #expect(oversized.isEmpty)
        #expect(buffer.append(Data("yyy\n{\"c\":3}\n".utf8)) == [.oversized, .message(Data("{\"c\":3}".utf8))])
        #expect(buffer.finish() == nil)
        _ = buffer.append(Data("{\"tail\":1}".utf8))
        #expect(buffer.finish() == .message(Data("{\"tail\":1}".utf8)))
    }

    @Test("JSON values round-trip; deep nesting is rejected")
    func json() throws {
        let value = try JSONValue.parse(Data(#"{"s":"x","i":42,"d":1.5,"b":true,"n":null,"a":[1,"two"],"o":{"k":"v"}}"#.utf8))
        #expect(value["s"]?.stringValue == "x")
        #expect(value["i"]?.intValue == 42)
        #expect(value["d"] == .double(1.5))
        #expect(value["b"]?.boolValue == true)
        #expect(value["n"] == .null)
        #expect(value["a"]?.arrayValue?.count == 2)
        #expect(try JSONValue.parse(value.encoded()) == value)
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(deep.utf8)) }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data("not json".utf8)) }
        #expect(String(decoding: JSONValue.object(["t": .string("a\nb")]).encoded(), as: UTF8.self) == #"{"t":"a\nb"}"#)
    }
}

@Suite("MCP: protocol and tools")
struct MCPServerTests {
    static func account(_ name: String, access: MCPAccess, readOnly: Bool = false) -> StorageAccount {
        var account = StorageAccount(kind: .minio, name: name, accessKeyID: "AK-\(name)")
        account.endpoint = "http://127.0.0.1:19900"
        account.mcpAccess = access
        account.isReadOnly = readOnly
        return account
    }

    struct Harness {
        let server: MCPServer
        let output: OutputSink
        let storage: FakeStorage
        let auditURL: URL

        func send(_ json: String) async { await server.receive(.message(Data(json.utf8))) }

        func call(_ id: Int, _ tool: String, _ arguments: String = "{}") async -> JSONValue? {
            await send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
            await server.waitForIdle()
            return output.response(id: id)
        }
    }

    static func harness(accounts: [StorageAccount], profile: String? = nil, forceReadOnly: Bool = false,
                        storage: FakeStorage = FakeStorage(), version: String = "2025-06-18") async -> Harness {
        let output = OutputSink()
        let auditURL = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-audit-\(UUID().uuidString).jsonl")
        let handler = BucketToolHandler(accounts: accounts, credentials: { _ in SigningCredentials(accessKeyID: "AK", secretAccessKey: "super-secret-value") },
                                        defaultConnection: profile, forceReadOnly: forceReadOnly, audit: MCPAuditLog(url: auditURL),
                                        storageFactory: { _, _ in storage })
        let server = MCPServer(handler: handler, version: "1.0.0", output: output.write)
        let harness = Harness(server: server, output: output, storage: storage, auditURL: auditURL)
        await harness.send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        await harness.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        return harness
    }

    static func payload(_ response: JSONValue?) -> JSONValue? {
        guard let text = response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue else { return nil }
        return try? JSONValue.parse(Data(text.utf8))
    }

    static func isError(_ response: JSONValue?) -> Bool { response?["result"]?["isError"]?.boolValue == true }

    static func errorText(_ response: JSONValue?) -> String { response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "" }

    @Test("initialize negotiates the protocol version and describes the server")
    func initialize() async throws {
        let modern = await Self.harness(accounts: [])
        let result = try #require(modern.output.response(id: 0)?["result"])
        #expect(result["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(result["serverInfo"]?["name"]?.stringValue == "ccinnbucket")
        #expect(result["serverInfo"]?["title"]?.stringValue == "CcinnBucket")
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["capabilities"]?["resources"] == nil)
        #expect(result["instructions"]?.stringValue?.contains("read-only") == true)
        let old = await Self.harness(accounts: [], version: "2024-11-05")
        #expect(old.output.response(id: 0)?["result"]?["protocolVersion"]?.stringValue == "2024-11-05")
        let unknown = await Self.harness(accounts: [], version: "1999-01-01")
        #expect(unknown.output.response(id: 0)?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
    }

    @Test("ping, unknown methods, parse errors, invalid params, notifications, batches, empty lists")
    func protocolErrors() async {
        let harness = await Self.harness(accounts: [])
        await harness.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":2,"method":"does/not/exist"}"#)
        await harness.send("{oops")
        await harness.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"arguments":{}}}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"no_such_tool"}}"#)
        await harness.send(#"{"jsonrpc":"2.0","method":"notifications/whatever"}"#)
        await harness.send(#"[{"jsonrpc":"2.0","id":7,"method":"ping"}]"#)
        await harness.send(#"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#)
        await harness.send(#"{"jsonrpc":"2.0","id":9,"method":"prompts/list"}"#)
        await harness.server.receive(.oversized)
        await harness.send(#"{"jsonrpc":"2.0","id":10,"method":"ping"}"#)
        await harness.server.waitForIdle()
        #expect(harness.output.response(id: 1)?["result"] == .object([:]))
        #expect(harness.output.response(id: 2)?["error"]?["code"]?.intValue == -32601)
        #expect(harness.output.messages.contains { $0["id"] == .null && $0["error"]?["code"]?.intValue == -32700 })
        #expect(harness.output.response(id: 4)?["error"]?["code"]?.intValue == -32602)
        #expect(harness.output.response(id: 5)?["error"]?["code"]?.intValue == -32602)
        #expect(harness.output.messages.contains { $0["error"]?["code"]?.intValue == -32600 })
        #expect(harness.output.response(id: 8)?["result"]?["resources"]?.arrayValue?.isEmpty == true)
        #expect(harness.output.response(id: 9)?["result"]?["prompts"]?.arrayValue?.isEmpty == true)
        #expect(harness.output.response(id: 10)?["result"] == .object([:]), "the server keeps working after an oversized line")
        #expect(harness.output.messages.filter { $0["error"]?["message"]?.stringValue?.contains("too large") == true }.count == 1)
    }

    @Test("tools/list: schemas are closed objects; write tools only when some account allows writes")
    func toolList() async throws {
        let readOnly = await Self.harness(accounts: [Self.account("ro", access: .readOnly)])
        await readOnly.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        await readOnly.server.waitForIdle()
        let tools = try #require(readOnly.output.response(id: 1)?["result"]?["tools"]?.arrayValue)
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        #expect(names == ["list_connections", "list_buckets", "list_objects", "head_object", "read_object_text", "object_versions"])
        for tool in tools {
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
            #expect(tool["inputSchema"]?["additionalProperties"] == .bool(false))
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true))
            #expect(tool["annotations"]?["openWorldHint"] == .bool(false))
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
        let writable = await Self.harness(accounts: [Self.account("rw", access: .readWrite)])
        await writable.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        await writable.server.waitForIdle()
        let all = try #require(writable.output.response(id: 1)?["result"]?["tools"]?.arrayValue)
        let deleteTool = try #require(all.first { $0["name"]?.stringValue == "delete_objects" })
        #expect(deleteTool["annotations"]?["destructiveHint"] == .bool(true))
        #expect(all.contains { $0["name"]?.stringValue == "presign_url" })
        let capped = await Self.harness(accounts: [Self.account("rw", access: .readWrite)], forceReadOnly: true)
        await capped.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        await capped.server.waitForIdle()
        #expect(capped.output.response(id: 1)?["result"]?["tools"]?.arrayValue?.contains { $0["name"]?.stringValue == "delete_objects" } == false)
    }

    @Test("connections: disabled accounts are invisible; ambiguity lists enabled names; --profile picks one")
    func connections() async throws {
        let accounts = [Self.account("alpha", access: .readOnly), Self.account("beta", access: .readWrite), Self.account("hidden", access: .disabled)]
        let harness = await Self.harness(accounts: accounts)
        let listed = try #require(Self.payload(await harness.call(1, "list_connections"))?["connections"]?.arrayValue)
        #expect(listed.compactMap { $0["name"]?.stringValue } == ["alpha", "beta"])
        #expect(!harness.output.messages.description.contains("super-secret-value"))
        let ambiguous = await harness.call(2, "list_buckets")
        #expect(Self.isError(ambiguous))
        #expect(Self.errorText(ambiguous).contains("alpha") && Self.errorText(ambiguous).contains("beta"))
        #expect(!Self.errorText(ambiguous).contains("hidden"))
        #expect(Self.isError(await harness.call(3, "list_buckets", #"{"connection":"hidden"}"#)))
        #expect(!Self.isError(await harness.call(4, "list_buckets", #"{"connection":"beta"}"#)))
        #expect(!Self.isError(await harness.call(5, "list_buckets", #"{"connection":"\#(accounts[0].id.uuidString)"}"#)))
        let profiled = await Self.harness(accounts: accounts, profile: "alpha")
        #expect(!Self.isError(await profiled.call(1, "list_buckets")))
        let single = await Self.harness(accounts: [Self.account("only", access: .readOnly)])
        #expect(!Self.isError(await single.call(1, "list_buckets")))
    }

    @Test("listing: bounded page size, continuation tokens, prefixes")
    func listing() async throws {
        let storage = FakeStorage()
        for index in 0..<1_500 { storage.put("b", String(format: "logs/%04d.txt", index), "x") }
        storage.put("b", "logs/sub/a.txt", "x")
        let harness = await Self.harness(accounts: [Self.account("a", access: .readOnly)], storage: storage)
        let first = try #require(Self.payload(await harness.call(1, "list_objects", #"{"bucket":"b","prefix":"logs/","max_keys":5000}"#)))
        #expect(first["objects"]?.arrayValue?.count == 1_000)
        #expect(first["commonPrefixes"]?.arrayValue == [.string("logs/sub/")])
        #expect(first["isTruncated"] == .bool(true))
        let token = try #require(first["nextContinuationToken"]?.stringValue)
        let second = try #require(Self.payload(await harness.call(2, "list_objects", #"{"bucket":"b","prefix":"logs/","continuation_token":"\#(token)"}"#)))
        #expect(second["objects"]?.arrayValue?.count == 200)
        #expect(Self.isError(await harness.call(3, "list_objects", #"{"prefix":"logs/"}"#)), "bucket is required")
        #expect(Self.isError(await harness.call(4, "list_objects", #"{"bucket":"b","unexpected":1}"#)), "unknown arguments are rejected")
        #expect(Self.isError(await harness.call(5, "list_objects", #"{"bucket":"b","continuation_token":"garbage"}"#)))
    }

    @Test("read_object_text: text, ranges, JSON, binary refusal, missing keys")
    func readText() async throws {
        let storage = FakeStorage()
        storage.put("b", "notes.txt", "hello world")
        storage.put("b", "data.json", #"{"a":1}"#, contentType: "application/json")
        storage.put("b", "img.png", Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]), contentType: "image/png")
        storage.put("b", "mystery.bin", Data([0x41, 0, 0x42]), contentType: "application/octet-stream")
        let harness = await Self.harness(accounts: [Self.account("a", access: .readOnly)], storage: storage)
        let text = try #require(Self.payload(await harness.call(1, "read_object_text", #"{"bucket":"b","key":"notes.txt","offset":6,"max_bytes":3}"#)))
        #expect(text["text"]?.stringValue == "wor")
        #expect(text["totalSize"]?.intValue == 11)
        #expect(text["truncated"] == .bool(true))
        #expect(Self.payload(await harness.call(2, "read_object_text", #"{"bucket":"b","key":"data.json"}"#))?["text"]?.stringValue == #"{"a":1}"#)
        let image = await harness.call(3, "read_object_text", #"{"bucket":"b","key":"img.png"}"#)
        #expect(Self.isError(image) && Self.errorText(image).contains("not text"))
        #expect(Self.isError(await harness.call(4, "read_object_text", #"{"bucket":"b","key":"mystery.bin"}"#)))
        let missing = await harness.call(5, "read_object_text", #"{"bucket":"b","key":"nope.txt"}"#)
        #expect(Self.isError(missing) && Self.errorText(missing).contains("NoSuchKey"))
        #expect(Self.isError(await harness.call(6, "read_object_text", #"{"bucket":"b","key":"notes.txt","max_bytes":10000000}"#)) == false)
    }

    @Test("writes are refused for read-only access without touching storage; allowed for read-write")
    func writes() async throws {
        let storage = FakeStorage()
        storage.put("b", "a.txt", "a")
        let readOnly = await Self.harness(accounts: [Self.account("ro", access: .readOnly)], storage: storage)
        let refused = await readOnly.call(1, "delete_objects", #"{"bucket":"b","keys":["a.txt"]}"#)
        #expect(Self.isError(refused))
        #expect(Self.isError(await readOnly.call(2, "presign_url", #"{"bucket":"b","key":"a.txt"}"#)))
        #expect(Self.isError(await readOnly.call(3, "put_text_object", #"{"bucket":"b","key":"n.txt","text":"x"}"#)))
        #expect(!storage.calls.contains("deleteObjects") && !storage.calls.contains("presignedURL") && !storage.calls.contains("putObject"))

        let lockedAccount = await Self.harness(accounts: [Self.account("locked", access: .readWrite, readOnly: true)], storage: storage)
        #expect(Self.isError(await lockedAccount.call(1, "delete_objects", #"{"bucket":"b","keys":["a.txt"]}"#)), "account read-only flag caps MCP")

        let writable = await Self.harness(accounts: [Self.account("rw", access: .readWrite)], storage: storage)
        #expect(!Self.isError(await writable.call(1, "put_text_object", #"{"bucket":"b","key":"n.txt","text":"new text"}"#)))
        #expect(!Self.isError(await writable.call(2, "copy_object", #"{"source_bucket":"b","source_key":"n.txt","destination_bucket":"b","destination_key":"m.txt"}"#)))
        let presigned = try #require(Self.payload(await writable.call(3, "presign_url", #"{"bucket":"b","key":"m.txt","expires_seconds":600}"#)))
        #expect(presigned["url"]?.stringValue?.contains("X-Amz-Expires=600") == true)
        let deleted = try #require(Self.payload(await writable.call(4, "delete_objects", #"{"bucket":"b","keys":["n.txt","m.txt"]}"#)))
        #expect(deleted["deleted"]?.arrayValue?.count == 2)
        let tooMany = (0..<101).map { "\"k\($0)\"" }.joined(separator: ",")
        #expect(Self.isError(await writable.call(5, "delete_objects", #"{"bucket":"b","keys":[\#(tooMany)]}"#)))
        #expect(Self.isError(await writable.call(6, "presign_url", #"{"bucket":"b","key":"m.txt","expires_seconds":9999999}"#)))
        let big = String(repeating: "x", count: (1 << 20) + 1)
        #expect(Self.isError(await writable.call(7, "put_text_object", #"{"bucket":"b","key":"big.txt","text":"\#(big)"}"#)))
    }

    @Test("results larger than the cap are shortened and flagged")
    func truncation() async throws {
        let storage = FakeStorage()
        let longName = String(repeating: "k", count: 900)
        for index in 0..<1_000 { storage.put("b", "\(longName)\(index)", "x") }
        let harness = await Self.harness(accounts: [Self.account("a", access: .readOnly)], storage: storage)
        let response = await harness.call(1, "list_objects", #"{"bucket":"b","max_keys":1000}"#)
        let text = Self.errorText(response)
        #expect(text.utf8.count <= MCPLimits.maximumResultBytes)
        #expect(Self.payload(response)?["truncated"] == .bool(true))
        #expect((Self.payload(response)?["objects"]?.arrayValue?.count ?? 0) > 0)
        #expect(response?["result"]?["structuredContent"] != nil)
        let old = await Self.harness(accounts: [Self.account("a", access: .readOnly)], storage: storage, version: "2024-11-05")
        #expect(await old.call(1, "list_buckets")?["result"]?["structuredContent"] == nil)
    }

    @Test("notifications/cancelled stops the tool call and suppresses its response")
    func cancellation() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let storage = FakeStorage(listHook: {
            started.withLock { $0 = true }
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                cancelled.withLock { $0 = true }
                throw error
            }
        })
        let harness = await Self.harness(accounts: [Self.account("a", access: .readOnly)], storage: storage)
        await harness.send(#"{"jsonrpc":"2.0","id":"slow","method":"tools/call","params":{"name":"list_objects","arguments":{"bucket":"b"}}}"#)
        for _ in 0..<200 where !started.withLock({ $0 }) { try await Task.sleep(nanoseconds: 5_000_000) }
        await harness.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"slow","reason":"user"}}"#)
        await harness.server.waitForIdle()
        #expect(cancelled.withLock { $0 })
        #expect(!harness.output.messages.contains { $0["id"] == .string("slow") })
    }

    @Test("every call is audited without secrets or object contents")
    func audit() async throws {
        let storage = FakeStorage()
        storage.put("b", "a.txt", "a")
        let harness = await Self.harness(accounts: [Self.account("rw", access: .readWrite)], storage: storage)
        _ = await harness.call(1, "put_text_object", #"{"bucket":"b","key":"secret-note.txt","text":"TOP-SECRET-CONTENT"}"#)
        _ = await harness.call(2, "head_object", #"{"bucket":"b","key":"missing"}"#)
        let log = try String(contentsOf: harness.auditURL, encoding: .utf8)
        let entries = log.split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
        #expect(entries.count == 2)
        #expect(entries[0]["tool"]?.stringValue == "put_text_object")
        #expect(entries[0]["connection"]?.stringValue == "rw")
        #expect(entries[0]["source"]?.stringValue == "mcp")
        #expect(entries[1]["error"]?.stringValue?.isEmpty == false)
        #expect(!log.contains("TOP-SECRET-CONTENT"))
        #expect(!log.contains("super-secret-value"))
    }
}
