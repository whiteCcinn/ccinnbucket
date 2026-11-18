import CcinnBucketKit
import Decompression
import Foundation
import StorageKit
import Testing

/// Stand-in decoder for the streaming tests: "decodes" by upper-casing ASCII, honours `maxOutput`, and requires the
/// stream to end with `!` (so truncation can be tested). Real gzip/zstd are covered in DecompressionTests and below.
private final class UppercaseDecoder: StreamDecoder {
    private var buffer: [UInt8] = []
    private var sawEnd = false

    func feed(_ data: Data) { buffer += data }

    func decode(into output: inout Data, maxOutput: Int, endOfInput: Bool) throws -> DecodeState {
        let count = min(maxOutput, buffer.count)
        let chunk = buffer.prefix(count)
        if chunk.contains(UInt8(ascii: "!")) { sawEnd = true }
        output.append(contentsOf: chunk.map { $0 >= 97 && $0 <= 122 ? $0 - 32 : $0 })
        buffer.removeFirst(count)
        if !buffer.isEmpty { return .outputFull }
        if endOfInput { if sawEnd { return .finished } else { throw DecompressionError.truncated } }
        return .needsInput
    }
}

@Suite("Preview streaming, formatting and saving")
struct PreviewStreamTests {
    private static let gzipMagic = Data([0x1F, 0x8B])

    private static func stream(_ storage: FakeStorage, key: String, size: Int, compression: CompressionFormat?, chunk: Int = 4_096) -> PreviewStream {
        PreviewStream(storage: storage, bucket: "b", key: key, versionID: nil, size: Int64(size), compression: compression,
                      chunkSize: chunk, maxChunkSize: chunk * 4) { _ in UppercaseDecoder() }
    }

    @Test("plain text: ranged chunks until the limit, then resumes where it stopped without refetching")
    func plainResume() async throws {
        let storage = FakeStorage()
        let text = String(repeating: "0123456789", count: 2_000) // 20,000 bytes
        storage.put("b", "log.txt", text)
        let preview = Self.stream(storage, key: "log.txt", size: 20_000, compression: nil)
        let first = try await preview.load(upTo: 5_000)
        #expect(first.data.count >= 5_000 && !first.isComplete)
        #expect(first.data.prefix(10) == Data("0123456789".utf8))
        #expect(storage.calls.filter { $0 == "getObject" }.count == 2, "4 KiB then 8 KiB")
        let all = try await preview.load(upTo: 1 << 20)
        #expect(all.isComplete && all.data == Data(text.utf8))
        #expect(all.progress.receivedBytes == 20_000 && all.progress.totalBytes == 20_000)
        #expect(all.eTag == "\"e\"")
    }

    @Test("compressed: progress is reported per chunk with received, total and decoded bytes")
    func compressedProgress() async throws {
        let storage = FakeStorage()
        var body = Self.gzipMagic + Data(String(repeating: "abc", count: 10_000).utf8)
        body.append(UInt8(ascii: "!"))
        storage.put("b", "x.log.gz", body, contentType: "application/gzip")
        let preview = Self.stream(storage, key: "x.log.gz", size: body.count, compression: .gzip)
        let reports = ProgressLog()
        let result = try await preview.load(upTo: 1 << 20) { reports.append($0) }
        #expect(result.isComplete)
        #expect(result.data.count == body.count)
        #expect(result.data.suffix(4) == Data("ABC!".utf8))
        let seen = reports.values
        #expect(!seen.isEmpty)
        #expect(seen.map(\.receivedBytes) == seen.map(\.receivedBytes).sorted(), "monotonic")
        #expect(seen.last?.receivedBytes == Int64(body.count))
        #expect(seen.allSatisfy { $0.totalBytes == Int64(body.count) && $0.compression == .gzip })
    }

    @Test("compressed: a stream that ends early is reported as truncated")
    func truncated() async throws {
        let storage = FakeStorage()
        let body = Self.gzipMagic + Data("no end marker".utf8)
        storage.put("b", "x.gz", body, contentType: nil)
        let preview = Self.stream(storage, key: "x.gz", size: body.count, compression: .gzip)
        await #expect(throws: DecompressionError.truncated) { _ = try await preview.load(upTo: 1 << 20) }
    }

    @Test("a .gz object that is not gzip (already decoded, or misnamed) is shown as it is")
    func sniffMismatch() async throws {
        let storage = FakeStorage()
        storage.put("b", "x.gz", "plain text!")
        let preview = Self.stream(storage, key: "x.gz", size: 11, compression: .gzip)
        let result = try await preview.load(upTo: 1 << 20)
        #expect(result.data == Data("plain text!".utf8), "not upper-cased: no decoder")
        #expect(result.progress.compression == nil && result.isComplete)
    }

    @Test("an object replaced while it streams is reported instead of mixing two versions")
    func replacedMidway() async throws {
        let storage = FakeStorage()
        storage.put("b", "log.txt", String(repeating: "a", count: 20_000))
        let preview = Self.stream(storage, key: "log.txt", size: 20_000, compression: nil)
        _ = try await preview.load(upTo: 3_000)
        storage.put("b", "log.txt", String(repeating: "b", count: 20_000))
        await #expect(throws: PreviewStream.StreamError.objectChanged) { _ = try await preview.load(upTo: 1 << 20) }
    }

    @Test("cancellation stops before the next request")
    func cancellation() async throws {
        let storage = FakeStorage()
        storage.put("b", "log.txt", String(repeating: "a", count: 100_000))
        let preview = Self.stream(storage, key: "log.txt", size: 100_000, compression: nil)
        let task = Task { try await preview.load(upTo: 1 << 20) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(storage.calls.filter { $0 == "getObject" }.count <= 1)
    }

    // MARK: Formatting

    @Test("JSON indenting keeps tokens as they are, handles strings and escapes, and tolerates truncation")
    func jsonIndent() {
        let input = #"{"a":[1,2.50,{"b":"x,y{\"]"}],"c":null,"e":{},"f":[]}"#
        let expected = """
        {
          "a": [
            1,
            2.50,
            {
              "b": "x,y{\\"]"
            }
          ],
          "c": null,
          "e": {},
          "f": []
        }
        """
        #expect(JSONIndenter.format(input) == expected)
        #expect(JSONIndenter.format(#"{"a": [1, "#) == "{\n  \"a\": [\n    1,\n    ")
        #expect(JSONIndenter.format("  [ ]  ") == "[]")
        #expect(JSONIndenter.format("") == "")
        #expect(JSONIndenter.format("]]]}}") == "]\n]\n]\n}\n}", "unbalanced input never goes below zero indent")
    }

    @Test("JSON indenting is bounded: deep nesting stops indenting deeper, and runaway growth returns the text as it is")
    func jsonIndentBounds() {
        let hostile = String(repeating: "[", count: 16_000)
        let clock = ContinuousClock()
        let started = clock.now
        let formatted = JSONIndenter.format(hostile)
        #expect(clock.now - started < .seconds(2))
        #expect(formatted.utf8.count <= hostile.utf8.count * JSONIndenter.maximumGrowth + 1_024)
        let deep = String(repeating: "[", count: 100) + "1" + String(repeating: "]", count: 100)
        let lines = JSONIndenter.format(deep).components(separatedBy: "\n")
        let longestIndent = lines.map { line in line.count - line.drop(while: { $0 == " " }).count }.max() ?? 0
        #expect(longestIndent <= JSONIndenter.maximumDepth * 2)
    }

    @Test("a compressed stream that decodes nothing for too long is stopped")
    func stalledDecoder() async throws {
        let storage = FakeStorage()
        storage.put("b", "x.gz", Self.gzipMagic + Data(repeating: 0x41, count: 50_000), contentType: nil)
        let preview = PreviewStream(storage: storage, bucket: "b", key: "x.gz", versionID: nil, size: 50_002, compression: .gzip,
                                    chunkSize: 4_096, maxChunkSize: 4_096, maxInputWithoutOutput: 10_000) { _ in SilentDecoder() }
        await #expect(throws: PreviewStream.StreamError.noProgress) { _ = try await preview.load(upTo: 1 << 20) }
        #expect(storage.calls.filter { $0 == "getObject" }.count <= 4)
    }

    @Test("JSON compaction removes only whitespace outside strings and undoes indenting exactly")
    func jsonCompact() {
        let minified = #"{"a":[1,2.50,{"b":"x, y {\" ] "}],"c":null,"e":{},"f":[],"g":"tab\tand  spaces"}"#
        #expect(JSONIndenter.compact(JSONIndenter.format(minified)) == minified)
        #expect(JSONIndenter.compact("{ \"a\" : [ 1 ,\n 2 ] }") == #"{"a":[1,2]}"#)
        #expect(JSONIndenter.compact(#"{"s":"  keep  "}"#) == #"{"s":"  keep  "}"#)
        #expect(JSONIndenter.compact("") == "")
    }

    @Test("long lines: longest line length, and display cuts only lines over the limit")
    func longLines() {
        #expect(TextLines.longestLine("ab\nabcd\n\nabc") == 4)
        #expect(TextLines.longestLine("") == 0)
        #expect(TextLines.longestLine(String(repeating: "x", count: 70_000)) == 70_000)
        let text = "short\n" + String(repeating: "y", count: 30) + "\nend"
        let cut = TextLines.cuttingLongLines(text, limit: 10)
        #expect(cut.text == "short\n" + String(repeating: "y", count: 10) + " … [20 more characters]\nend")
        #expect(cut.linesCut == 1)
        let untouched = TextLines.cuttingLongLines("a\nb", limit: 10)
        #expect(untouched.text == "a\nb" && untouched.linesCut == 0)
    }

    @Test("binary detection, strict UTF-8 and hex dump")
    func textHelpers() {
        #expect(TextSniffer.isLikelyBinary(Data([0x48, 0x00, 0x49])))
        #expect(!TextSniffer.isLikelyBinary(Data("héllo\nworld\t".utf8)))
        #expect(TextSniffer.strictUTF8(Data("héllo".utf8)) == "héllo")
        #expect(TextSniffer.strictUTF8(Data([0xC3])) == nil)
        let dump = HexDump.format(Data("Hello, world!\u{0}\u{1}xyz".utf8), limit: 1_024)
        // `hexdump -C` layout: the ASCII column starts at character 60 on every line.
        let first = "00000000  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 00 01 78  |Hello, world!..x|"
        let second = "00000010  79 7a" + String(repeating: " ", count: 60 - 15) + "|yz|"
        #expect(dump == first + "\n" + second)
        #expect(HexDump.format(Data(repeating: 0x41, count: 40), limit: 16).hasSuffix("|AAAAAAAAAAAAAAAA|\n… 24 more bytes"))
    }

    // MARK: Saving edits

    @Test("saving keeps headers, metadata, storage class and tags, and refuses when the object changed")
    func saveKeepsEverything() async throws {
        let storage = FakeStorage()
        let options = ObjectWriteOptions(contentType: "application/json", cacheControl: "max-age=60", storageClass: "STANDARD_IA",
                                         userMetadata: ["team": "adx"], tags: [ObjectTag(key: "env", value: "prod")])
        storage.put("b", "c.json", Data("{}".utf8), options: options)
        let eTag = try await storage.headObject(bucket: "b", key: "c.json", versionID: nil).eTag
        let body = try ObjectTextSaver.encode("{\"a\":1}", compression: nil)
        _ = try await ObjectTextSaver.save(body: body, bucket: "b", key: "c.json", expectedETag: eTag, storage: storage)
        let saved = try #require(storage.stored("b", "c.json"))
        #expect(saved.data == Data("{\"a\":1}".utf8))
        #expect(saved.options.contentType == "application/json" && saved.options.cacheControl == "max-age=60")
        #expect(saved.options.storageClass == "STANDARD_IA" && saved.options.userMetadata == ["team": "adx"])
        #expect(saved.tags == [ObjectTag(key: "env", value: "prod")])

        // The object is now newer than `eTag`: a second save from the old preview is refused.
        await #expect(throws: ObjectTextSaver.SaveError.changedOnServer) {
            _ = try await ObjectTextSaver.save(body: body, bucket: "b", key: "c.json", expectedETag: eTag, storage: storage)
        }
        #expect(storage.calls.filter { $0 == "putObject" }.count == 1, "only the first save uploads (the setup writes directly)")
    }

    @Test("tags are kept even when HEAD does not report a tag count (AWS S3)")
    func tagsWithoutCount() async throws {
        let storage = FakeStorage(headReportsTagCount: false)
        storage.put("b", "c.txt", Data("a".utf8), options: ObjectWriteOptions(contentType: "text/plain", tags: [ObjectTag(key: "team", value: "adx")]))
        let eTag = try await storage.headObject(bucket: "b", key: "c.txt", versionID: nil).eTag
        #expect(try await storage.headObject(bucket: "b", key: "c.txt", versionID: nil).tagCount == nil)
        try await ObjectTextSaver.save(body: Data("b".utf8), bucket: "b", key: "c.txt", expectedETag: eTag, storage: storage)
        #expect(storage.stored("b", "c.txt")?.tags == [ObjectTag(key: "team", value: "adx")])
    }

    @Test("ETags compare without quotes and case (S3 and OSS spell them differently)")
    func eTagComparison() {
        #expect(ObjectTextSaver.sameETag("\"ABC\"", "abc"))
        #expect(!ObjectTextSaver.sameETag("\"abc\"", "\"abd\""))
        #expect(!ObjectTextSaver.sameETag(nil, "\"abc\""))
    }
}

/// Consumes input and never produces output.
private final class SilentDecoder: StreamDecoder {
    func feed(_ data: Data) {}
    func decode(into output: inout Data, maxOutput: Int, endOfInput: Bool) throws -> DecodeState { .needsInput }
}

/// Collects progress reports from the `@Sendable` callback.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PreviewProgress] = []

    func append(_ value: PreviewProgress) { lock.withLock { stored.append(value) } }
    var values: [PreviewProgress] { lock.withLock { stored } }
}
