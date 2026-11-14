// CcinnBucket — a native object storage client for macOS (Amazon S3, S3-compatible services, Alibaba Cloud OSS).
import CcinnBucketKit
import Foundation
import os

if CommandLine.arguments.dropFirst().first == "mcp" {
    // Headless Model Context Protocol server over stdio: no NSApplication, no windows, no Dock icon.
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    let finished = DispatchSemaphore(value: 0)
    let status = OSAllocatedUnfairLock<Int32>(initialState: 0)
    Task.detached {
        let code = await MCPLauncher.run(arguments: arguments)
        status.withLock { $0 = code }
        finished.signal()
    }
    finished.wait()
    exit(status.withLock { $0 })
} else {
    CcinnBucketApp.main()
}
