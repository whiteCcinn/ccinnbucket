import Foundation
import StorageKit
import StorageSigning

/// Entry point of `CcinnBucket mcp [--profile <name|id>] [--read-only]`: loads the saved accounts, then
/// serves MCP over stdin/stdout until stdin closes. Nothing but protocol messages is written to stdout.
public enum MCPLauncher {
    /// Points the account store at another folder (used by tests and isolated setups).
    public static let accountsDirectoryVariable = "CCINNBUCKET_ACCOUNTS_DIR"
    /// TEST ONLY: JSON object mapping account names or ids to `{"secretAccessKey": …, "sessionToken": …}`.
    /// When set, the Keychain is not consulted. Never use it with real credentials.
    public static let insecureTestSecretsVariable = "CCINNBUCKET_TEST_INSECURE_SECRETS"

    public static let version = "1.0.0"

    public static func run(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
        signal(SIGPIPE, SIG_IGN) // A client that goes away must not kill us mid-write.
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            FileHandle.standardError.write(Data("usage: CcinnBucket mcp [--profile <name|id>] [--read-only]\n".utf8))
            return 0
        }
        let directory = environment[accountsDirectoryVariable].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AccountRepository.defaultDirectory
        let testSecrets = environment[insecureTestSecretsVariable].flatMap { try? JSONValue.parse(Data($0.utf8)) }
        let repository = AccountRepository(directory: directory, secrets: testSecrets == nil ? KeychainSecretStore() : InMemorySecretStore())
        let accounts: [StorageAccount]
        do {
            accounts = try repository.load()
        } catch {
            log("ccinnbucket mcp: could not read accounts: \(error.localizedDescription)")
            accounts = []
        }
        let credentials: @Sendable (StorageAccount) -> SigningCredentials? = { account in
            if let testSecrets {
                guard let entry = testSecrets[account.displayName] ?? testSecrets[account.id.uuidString],
                      let secret = entry["secretAccessKey"]?.stringValue else { return nil }
                return SigningCredentials(accessKeyID: account.accessKeyID, secretAccessKey: secret, sessionToken: entry["sessionToken"]?.stringValue)
            }
            return repository.credentials(for: account)
        }
        let handler = BucketToolHandler(accounts: accounts, credentials: credentials, defaultConnection: value("--profile"),
                                        forceReadOnly: arguments.contains("--read-only"),
                                        audit: MCPAuditLog(url: directory.appendingPathComponent("mcp-audit.jsonl")))
        let server = MCPServer(handler: handler, version: version, output: writeLine)
        let enabled = accounts.filter { $0.mcpAccess != .disabled }.count
        log("ccinnbucket mcp: \(enabled) of \(accounts.count) accounts enabled for AI access\(arguments.contains("--read-only") ? " (read-only)" : "")")
        await serve(server)
        return 0
    }

    /// Reads newline-delimited messages from stdin on a dedicated thread and feeds them to `server`.
    static func serve(_ server: MCPServer) async {
        let lines = AsyncStream<MCPLineBuffer.Line> { continuation in
            let thread = Thread {
                var buffer = MCPLineBuffer()
                var chunk = [UInt8](repeating: 0, count: 64 << 10)
                while true {
                    let count = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { break }
                    for line in buffer.append(Data(chunk[0..<count])) { continuation.yield(line) }
                }
                if let last = buffer.finish() { continuation.yield(last) }
                continuation.finish()
            }
            thread.name = "ccinnbucket.mcp.stdin"
            thread.start()
        }
        for await line in lines { await server.receive(line) }
        await server.waitForIdle()
    }

    /// Writes one message plus newline to stdout with POSIX `write` (never throws, never raises on EPIPE).
    static let writeLine: @Sendable (Data) -> Void = { data in
        var message = data
        message.append(UInt8(ascii: "\n"))
        message.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let result = write(STDOUT_FILENO, base.advanced(by: written), raw.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    return
                }
                written += result
            }
        }
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

