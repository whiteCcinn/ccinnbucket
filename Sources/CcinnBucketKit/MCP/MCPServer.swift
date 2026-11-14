import Foundation

/// A tool as advertised by `tools/list`.
public struct MCPTool: Sendable, Hashable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool, destructive: Bool, idempotent: Bool) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
    }

    var json: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent),
                "openWorldHint": .bool(false),
            ]),
        ])
    }
}

/// Outcome of a tool call: a JSON object, or a message for the model (`isError: true`).
public enum MCPToolResult: Sendable, Hashable {
    case success(JSONValue)
    case failure(String)
}

/// Supplies and executes tools. Must honour Swift task cancellation.
public protocol MCPToolHandler: Sendable {
    var serverName: String { get }
    var serverTitle: String { get }
    var instructions: String { get }
    func tools() async -> [MCPTool]
    func knows(tool name: String) async -> Bool
    func call(tool name: String, arguments: [String: JSONValue]) async -> MCPToolResult
}

/// JSON-RPC 2.0 / Model Context Protocol dispatcher. Requests are processed concurrently (each tool call in
/// its own task, cancellable with `notifications/cancelled`); all output goes through this actor, so
/// messages are written one at a time.
public actor MCPServer {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let latestVersion = "2025-06-18"

    private let handler: any MCPToolHandler
    private let version: String
    private let output: @Sendable (Data) -> Void
    private var protocolVersion = MCPServer.latestVersion
    private var inFlight: [JSONValue: Task<Void, Never>] = [:]
    private var cancelled = Set<JSONValue>()

    public init(handler: any MCPToolHandler, version: String, output: @escaping @Sendable (Data) -> Void) {
        self.handler = handler
        self.version = version
        self.output = output
    }

    public func receive(_ line: MCPLineBuffer.Line) async {
        switch line {
        case .oversized:
            sendError(id: .null, code: -32700, message: "Message too large (limit \(MCPLimits.maximumMessageBytes / (1 << 20)) MB)")
        case let .message(data):
            let message: JSONValue
            do {
                message = try JSONValue.parse(data)
            } catch {
                sendError(id: .null, code: -32700, message: "Parse error")
                return
            }
            await handle(message)
        }
    }

    /// Waits until every in-flight tool call has finished (used at shutdown and in tests).
    public func waitForIdle() async {
        while !inFlight.isEmpty {
            for task in Array(inFlight.values) { await task.value }
        }
    }

    private func handle(_ message: JSONValue) async {
        guard case let .object(object) = message else {
            sendError(id: .null, code: -32600, message: message.arrayValue != nil ? "Batch requests are not supported" : "Invalid request")
            return
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            if let id { sendError(id: id, code: -32600, message: "Invalid request") }
            return
        }
        let params = object["params"]?.objectValue ?? [:]
        guard let id, id != .null else {
            handleNotification(method, params: params)
            return
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.latestVersion
            protocolVersion = Self.supportedVersions.contains(requested) ? requested : Self.latestVersion
            sendResult(id: id, .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string(handler.serverName), "title": .string(handler.serverTitle), "version": .string(version)]),
                "instructions": .string(handler.instructions),
            ]))
        case "ping":
            sendResult(id: id, .object([:]))
        case "tools/list":
            sendResult(id: id, .object(["tools": .array(await handler.tools().map(\.json))]))
        case "resources/list":
            sendResult(id: id, .object(["resources": .array([])]))
        case "resources/templates/list":
            sendResult(id: id, .object(["resourceTemplates": .array([])]))
        case "prompts/list":
            sendResult(id: id, .object(["prompts": .array([])]))
        case "tools/call":
            await startToolCall(id: id, params: params)
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleNotification(_ method: String, params: [String: JSONValue]) {
        guard method == "notifications/cancelled", let requestID = params["requestId"], let task = inFlight[requestID] else { return }
        cancelled.insert(requestID)
        task.cancel()
    }

    private func startToolCall(id: JSONValue, params: [String: JSONValue]) async {
        guard let name = params["name"]?.stringValue, !name.isEmpty else {
            sendError(id: id, code: -32602, message: "Invalid params: missing tool name")
            return
        }
        let arguments: [String: JSONValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case let .object(value)?: arguments = value
        default:
            sendError(id: id, code: -32602, message: "Invalid params: arguments must be an object")
            return
        }
        guard await handler.knows(tool: name) else {
            sendError(id: id, code: -32602, message: "Unknown tool: \(name)")
            return
        }
        guard inFlight[id] == nil else {
            sendError(id: id, code: -32600, message: "A request with this id is already running")
            return
        }
        let handler = handler
        inFlight[id] = Task { [weak self] in
            let result = await handler.call(tool: name, arguments: arguments)
            await self?.finishToolCall(id: id, result: result)
        }
    }

    private func finishToolCall(id: JSONValue, result: MCPToolResult) {
        inFlight[id] = nil
        if cancelled.remove(id) != nil { return } // Cancelled requests get no response.
        switch result {
        case let .success(value):
            let text = String(decoding: value.encoded(), as: UTF8.self)
            var body: [String: JSONValue] = ["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(false)]
            if protocolVersion >= "2025-06-18", case .object = value { body["structuredContent"] = value }
            sendResult(id: id, .object(body))
        case let .failure(message):
            sendResult(id: id, .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)]))
        }
    }

    private func sendResult(id: JSONValue, _ result: JSONValue) {
        output(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encoded())
    }

    private func sendError(id: JSONValue, code: Int, message: String) {
        output(JSONValue.object(["jsonrpc": .string("2.0"), "id": id,
                                 "error": .object(["code": .int(Int64(code)), "message": .string(message)])]).encoded())
    }
}
