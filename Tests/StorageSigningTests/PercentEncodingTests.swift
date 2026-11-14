import Foundation
import StorageSigning
import Testing

@Suite("Percent encoding and credentials")
struct PercentEncodingTests {
    @Test("RFC 3986 unreserved characters stay literal; everything else is %XX of UTF-8")
    func encode() {
        #expect(PercentEncoding.encode("AZaz09-_.~", keepSlash: false) == "AZaz09-_.~")
        #expect(PercentEncoding.encode("a b+c/d", keepSlash: false) == "a%20b%2Bc%2Fd")
        #expect(PercentEncoding.encode("a b+c/d", keepSlash: true) == "a%20b%2Bc/d")
        #expect(PercentEncoding.encode("é✓😀", keepSlash: true) == "%C3%A9%E2%9C%93%F0%9F%98%80")
        #expect(PercentEncoding.encode("%25", keepSlash: true) == "%2525")
        #expect(PercentEncoding.encode("", keepSlash: true) == "")
        #expect(PercentEncoding.encodePath("/a//b/./c/../d/") == "/a//b/./c/../d/")
    }

    @Test("query strings keep order; empty values keep the equals sign")
    func queryString() {
        let parameters = [QueryParameter("prefix", ""), QueryParameter("list-type", "2"), QueryParameter("a b", "c&d=e")]
        #expect(PercentEncoding.queryString(parameters) == "prefix=&list-type=2&a%20b=c%26d%3De")
        #expect(PercentEncoding.queryString([]) == "")
    }

    @Test("canonical query sorts by encoded name, then encoded value, bytewise")
    func canonicalQuery() {
        let parameters = [QueryParameter("b", "2"), QueryParameter("a", "z"), QueryParameter("a", "y"),
                          QueryParameter("B", "1"), QueryParameter("uploads", "")]
        #expect(PercentEncoding.canonicalQuery(parameters) == "B=1&a=y&a=z&b=2&uploads=")
    }

    @Test("decoding: percent and form variants, malformed input")
    func decode() {
        #expect(PercentEncoding.decode("a+b%2Bc%20d", plusAsSpace: true) == "a b+c d")
        #expect(PercentEncoding.decode("a+b%2Bc%20d", plusAsSpace: false) == "a+b+c d")
        #expect(PercentEncoding.decode("%E6%97%A5%E6%9C%AC", plusAsSpace: false) == "日本")
        #expect(PercentEncoding.decode("%zz", plusAsSpace: false) == nil)
        #expect(PercentEncoding.decode("%E6%97", plusAsSpace: false) == nil, "invalid UTF-8 must not decode")
        #expect(PercentEncoding.decode("100%", plusAsSpace: false) == nil)
        #expect(PercentEncoding.decode("", plusAsSpace: true) == "")
    }

    @Test("credentials never reveal the secret key or session token")
    func credentialsRedacted() {
        let credentials = SigningCredentials(accessKeyID: "AKIDVISIBLE", secretAccessKey: "super-secret-value",
                                             sessionToken: "token-value-123")
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in [String(describing: credentials), String(reflecting: credentials), "\(credentials)", dumped] {
            #expect(!text.contains("super-secret-value"))
            #expect(!text.contains("token-value-123"))
        }
        #expect(String(describing: credentials).contains("AKID"))
        #expect(credentials.isTemporary)
    }

    @Test("ISO 8601 basic timestamps are UTC and locale independent")
    func timestamps() {
        let date = Date(timeIntervalSince1970: 1_369_353_600) // 2013-05-24T00:00:00Z
        #expect(SigningTime.amzDate(date) == "20130524T000000Z")
        #expect(SigningTime.dateStamp(date) == "20130524")
        #expect(SigningTime.amzDate(Date(timeIntervalSince1970: -1)) == "19691231T235959Z")
    }
}
