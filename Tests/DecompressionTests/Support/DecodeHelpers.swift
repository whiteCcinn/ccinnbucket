import CryptoKit
@testable import Decompression
import Foundation

struct FixtureEntry: Decodable {
    let file: String
    let format: String
    let size: Int
    let sha256: String
}

enum Fixtures {
    static let directory: URL = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    static var manifest: [FixtureEntry] {
        let data = try! Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try! JSONDecoder().decode([FixtureEntry].self, from: data)
    }

    static func data(_ name: String) -> Data {
        try! Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func format(_ entry: FixtureEntry) -> CompressionFormat {
        entry.format == "zstd" ? .zstd : .gzip
    }

    /// The plaintext of a fixture, decoded in one go (used as an input for encoder tests).
    static func plaintext(_ name: String) throws -> Data {
        let entry = manifest.first { $0.file == name }!
        return try Decode.all(data(name), format: format(entry))
    }
}

enum Decode {
    struct LoopError: Error {}

    /// Feeds `input` in chunks of `chunk` bytes, decoding with `maxOutput` per call, until the stream finishes.
    /// Throws whatever the decoder throws; `LoopError` when it stops making progress (a decoder bug).
    static func all(_ input: Data, format: CompressionFormat, chunk: Int = Int.max, maxOutput: Int = 1 << 20) throws -> Data {
        let decoder = format.makeDecoder()
        var output = Data()
        var offset = 0
        var stalls = 0
        while true {
            if offset < input.count {
                let end = offset + min(chunk, input.count - offset)
                decoder.feed(input.subdata(in: offset..<end))
                offset = end
            }
            let endOfInput = offset >= input.count
            let before = output.count
            let state = try decoder.decode(into: &output, maxOutput: maxOutput, endOfInput: endOfInput)
            switch state {
            case .finished:
                return output
            case .outputFull:
                stalls = output.count > before ? 0 : stalls + 1
            case .needsInput:
                if endOfInput { stalls += 1 } else { stalls = 0 }
            }
            if stalls > 3 { throw LoopError() }
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Deterministic generator for fuzz tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum ExternalTool {
    /// Path of a CLI when installed (zstd from Homebrew is common on developer Macs, not guaranteed on CI).
    static func find(_ name: String) -> String? {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs `tool arguments` with `input` on stdin and returns stdout (nil on a non-zero exit).
    static func run(_ tool: String, _ arguments: [String], input: Data) throws -> Data? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("decompression-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input")
        let outputURL = directory.appendingPathComponent("output")
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = try FileHandle(forReadingFrom: inputURL)
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try Data(contentsOf: outputURL)
    }
}
