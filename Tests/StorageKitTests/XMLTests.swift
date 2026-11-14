import Foundation
@testable import StorageKit
import Testing

@Suite("Bounded XML")
struct XMLTests {
    @Test("parses elements, text, attributes and strips namespace prefixes")
    func parse() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Name>bucket</Name>
          <Contents><Key>a &amp; b</Key><Size>12</Size></Contents>
          <Contents><Key>c</Key><Size>3</Size></Contents>
          <xsi:Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group"><URI>u</URI></xsi:Grantee>
        </ListBucketResult>
        """
        let root = try XMLReader.parse(Data(xml.utf8))
        #expect(root.name == "ListBucketResult")
        #expect(root.childText("Name") == "bucket")
        #expect(root.children("Contents").count == 2)
        #expect(root.children("Contents").first?.childText("Key") == "a & b")
        #expect(root.child("Grantee")?.attributes["type"] == "Group")
        #expect(root.child("Missing") == nil)
    }

    @Test("rejects DTDs and entity declarations (billion laughs, XXE)")
    func rejectsDTD() {
        let laughs = """
        <?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;">]><r>&lol2;</r>
        """
        let xxe = """
        <?xml version="1.0"?><!doctype r [<!ENTITY x SYSTEM "file:///etc/passwd">]><r>&x;</r>
        """
        #expect(throws: StorageError.self) { try XMLReader.parse(Data(laughs.utf8)) }
        #expect(throws: StorageError.self) { try XMLReader.parse(Data(xxe.utf8)) }
    }

    @Test("enforces depth, element count, text and input size limits")
    func limits() {
        let deep = String(repeating: "<a>", count: 10_000) + String(repeating: "</a>", count: 10_000)
        #expect(throws: StorageError.self) { try XMLReader.parse(Data(deep.utf8)) }
        let many = "<r>" + String(repeating: "<i/>", count: 2_000) + "</r>"
        #expect(throws: StorageError.self) { try XMLReader.parse(Data(many.utf8), limits: XMLLimits(maxBytes: 1 << 20, maxDepth: 8, maxElements: 1_000, maxTextBytes: 1 << 20)) }
        let longText = "<r>" + String(repeating: "x", count: 5_000) + "</r>"
        #expect(throws: StorageError.self) { try XMLReader.parse(Data(longText.utf8), limits: XMLLimits(maxBytes: 1 << 20, maxDepth: 8, maxElements: 10, maxTextBytes: 1_000)) }
        #expect(throws: StorageError.self) { try XMLReader.parse(Data(longText.utf8), limits: XMLLimits(maxBytes: 100, maxDepth: 8, maxElements: 10, maxTextBytes: 1_000_000)) }
    }

    @Test("malformed, truncated and random input throws instead of crashing")
    func malformed() {
        for text in ["", "<", "<a>", "<a></b>", "not xml", "<a>\u{1}</a>", "<?xml version=\"1.0\"?>"] {
            #expect(throws: StorageError.self) { try XMLReader.parse(Data(text.utf8)) }
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let length = Int.random(in: 0..<200, using: &generator)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = try? XMLReader.parse(Data([UInt8](Data("<r>".utf8)) + bytes))
        }
    }

    @Test("writer escapes markup and carriage returns; detects unrepresentable text")
    func writer() throws {
        var writer = XMLWriter()
        writer.open("Delete", attributes: ["xmlns": "http://s3.amazonaws.com/doc/2006-03-01/"])
        writer.element("Quiet", "true")
        writer.open("Object")
        writer.element("Key", "a<b>&\"c\"'d\r\ne\tf")
        writer.close("Object")
        writer.close("Delete")
        let xml = writer.result
        #expect(xml.contains("<Key>a&lt;b&gt;&amp;&quot;c&quot;&apos;d&#xD;\ne\tf</Key>"))
        let parsed = try XMLReader.parse(Data(xml.utf8))
        #expect(parsed.child("Object")?.childText("Key") == "a<b>&\"c\"'d\r\ne\tf")
        #expect(XMLWriter.isRepresentable("normal key/ü😀"))
        #expect(!XMLWriter.isRepresentable("bad\u{1}key"))
        #expect(!XMLWriter.isRepresentable("bad\u{FFFE}"))
    }

    @Test("pretty printer indents nested documents")
    func prettyPrint() throws {
        let root = try XMLReader.parse(Data("<a><b>1</b><c><d>x</d></c></a>".utf8))
        #expect(XMLWriter.prettyPrinted(root) == "<a>\n  <b>1</b>\n  <c>\n    <d>x</d>\n  </c>\n</a>")
    }

    @Test("ISO 8601 timestamps with and without fractions")
    func timestamps() {
        #expect(StorageDate.parseISO8601("2009-10-12T17:50:30.000Z") == Date(timeIntervalSince1970: 1_255_369_830))
        #expect(StorageDate.parseISO8601("2009-10-12T17:50:30Z") == Date(timeIntervalSince1970: 1_255_369_830))
        #expect(StorageDate.parseISO8601("2009-10-12T17:50:30.5+00:00") == Date(timeIntervalSince1970: 1_255_369_830.5))
        #expect(StorageDate.parseISO8601("garbage") == nil)
        #expect(StorageDate.parseISO8601("2009-13-45T99:99:99Z") == nil)
    }
}
