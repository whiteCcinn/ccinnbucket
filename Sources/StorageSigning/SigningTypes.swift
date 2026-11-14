import CryptoKit
import Foundation

/// Access key pair (plus optional STS session token).
///
/// The secret and token are redacted from every textual and reflected representation, so credentials
/// can be logged or interpolated by accident without leaking.
public struct SigningCredentials: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        let token = sessionToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionToken = (token?.isEmpty ?? true) ? nil : token
    }

    /// Temporary (STS) credentials carry a session token.
    public var isTemporary: Bool { sessionToken != nil }

    /// Access key ID with its middle elided, e.g. `AKIA…MPLE`.
    public var maskedAccessKeyID: String {
        guard accessKeyID.count > 8 else { return accessKeyID.isEmpty ? "" : String(accessKeyID.prefix(2)) + "…" }
        return String(accessKeyID.prefix(4)) + "…" + String(accessKeyID.suffix(4))
    }

    public var description: String {
        "SigningCredentials(accessKeyID: \(maskedAccessKeyID), secretAccessKey: <redacted>\(isTemporary ? ", sessionToken: <redacted>" : ""))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["accessKeyID": maskedAccessKeyID, "secretAccessKey": "<redacted>",
                                "sessionToken": isTemporary ? "<redacted>" : "nil"], displayStyle: .struct)
    }
}

/// One HTTP header. Names are case-insensitive; values are sent exactly as given.
public struct HTTPHeader: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// One decoded query parameter. An empty value is a bare sub-resource such as `?uploads`.
public struct QueryParameter: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String = "") {
        self.name = name
        self.value = value
    }
}

/// Everything a signer needs to know about a request. Paths and parameters are *decoded*; the signers
/// encode them exactly once, and the transport must send the same encoded forms
/// (`PercentEncoding.encodePath(path)` and `PercentEncoding.queryString(query)`).
public struct SigningRequest: Sendable, Hashable {
    public var method: String
    /// Value of the `Host` header: host name, plus `:port` when the port is not the scheme default.
    public var host: String
    /// Decoded absolute URL path, e.g. `/bucket/photos/a b.jpg` (path-style) or `/photos/a b.jpg` (virtual-hosted).
    public var path: String
    public var query: [QueryParameter]
    public var headers: [HTTPHeader]
    /// Bucket and key, used by OSS whose canonical resource is always `/<bucket>/<key>` whatever the host style.
    public var bucket: String?
    public var key: String?

    public init(method: String, host: String, path: String, query: [QueryParameter] = [], headers: [HTTPHeader] = [],
                bucket: String? = nil, key: String? = nil) {
        self.method = method.uppercased()
        self.host = host
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.query = query
        self.headers = headers
        self.bucket = bucket
        self.key = key
    }

    /// First header with this name (case-insensitive).
    public func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.name.lowercased() == lowered }?.value
    }
}

/// Headers produced by a header signer, plus the intermediate strings (useful for diagnostics and tests).
public struct SignatureResult: Sendable, Hashable {
    /// Headers to add to the request (authorization, dates, content hash, security token).
    public var headers: [HTTPHeader]
    public var canonicalRequest: String
    public var stringToSign: String
    public var signature: String

    public func header(_ name: String) -> String? {
        let lowered = name.lowercased()
        return headers.first { $0.name.lowercased() == lowered }?.value
    }
}

/// A presigned request: the complete encoded query string (original parameters first, then the
/// authentication parameters and the signature).
public struct PresignResult: Sendable, Hashable {
    public var queryString: String
    public var canonicalRequest: String
    public var stringToSign: String
    public var signature: String
}

public enum SigningError: Error, Sendable, Hashable, LocalizedError {
    case invalidExpiry(seconds: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidExpiry(seconds, maximum):
            "A link must expire between 1 second and \(maximum / 86_400) days (got \(seconds) seconds)."
        }
    }
}

/// Payload hash values for `x-amz-content-sha256` / `x-oss-content-sha256`.
public enum PayloadHash {
    public static let unsigned = "UNSIGNED-PAYLOAD"
    public static let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    public static func sha256Hex(_ data: Data) -> String { Hashing.sha256Hex(data) }
}

/// Small wrappers around CryptoKit.
public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    public static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }

    public static func md5Base64(_ data: Data) -> String { Data(Insecure.MD5.hash(data: data)).base64EncodedString() }

    static func hmacSHA256(key: some ContiguousBytes, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hmacSHA1Base64(key: String, _ message: String) -> String {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8))))
            .base64EncodedString()
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(64)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Locale-independent UTC time formatting for signatures (no `DateFormatter`, no shared state).
public enum SigningTime {
    /// Whole seconds since 1970, clamped so that non-finite or absurd dates never trap.
    public static func unixSeconds(_ date: Date) -> Int {
        let value = date.timeIntervalSince1970
        guard value.isFinite else { return 0 }
        let clamped = min(max(value.rounded(.down), -62_135_596_800), 253_402_300_799) // years 0001 … 9999
        return Int(clamped)
    }

    static func components(_ date: Date) -> tm {
        var seconds = time_t(unixSeconds(date))
        var result = tm()
        gmtime_r(&seconds, &result)
        return result
    }

    /// `yyyyMMdd'T'HHmmss'Z'`
    public static func amzDate(_ date: Date) -> String {
        let t = components(date)
        return pad(Int(t.tm_year) + 1900, 4) + pad(Int(t.tm_mon) + 1, 2) + pad(Int(t.tm_mday), 2) + "T"
            + pad(Int(t.tm_hour), 2) + pad(Int(t.tm_min), 2) + pad(Int(t.tm_sec), 2) + "Z"
    }

    /// `yyyyMMdd`
    public static func dateStamp(_ date: Date) -> String { String(amzDate(date).prefix(8)) }

    /// RFC 1123, e.g. `Sat, 14 Nov 2026 08:30:15 GMT`.
    public static func httpDate(_ date: Date) -> String {
        let t = components(date)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekday = days.indices.contains(Int(t.tm_wday)) ? days[Int(t.tm_wday)] : "Sun"
        let month = months.indices.contains(Int(t.tm_mon)) ? months[Int(t.tm_mon)] : "Jan"
        return "\(weekday), \(pad(Int(t.tm_mday), 2)) \(month) \(pad(Int(t.tm_year) + 1900, 4)) "
            + "\(pad(Int(t.tm_hour), 2)):\(pad(Int(t.tm_min), 2)):\(pad(Int(t.tm_sec), 2)) GMT"
    }

    /// Parses RFC 1123 dates (`Date` response headers). Returns nil for anything else.
    public static func parseHTTPDate(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 6, parts[5] == "GMT" || parts[5] == "UTC",
              let day = Int(parts[1]), (1...31).contains(day),
              let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"].firstIndex(of: String(parts[2])),
              let year = Int(parts[3]), (1970...9999).contains(year) else { return nil }
        let clock = parts[4].split(separator: ":")
        guard clock.count == 3, let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        var t = tm()
        t.tm_year = Int32(year - 1900)
        t.tm_mon = Int32(month)
        t.tm_mday = Int32(day)
        t.tm_hour = Int32(hour)
        t.tm_min = Int32(minute)
        t.tm_sec = Int32(second)
        let seconds = timegm(&t)
        guard seconds != -1 || (year == 1969) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }
}
