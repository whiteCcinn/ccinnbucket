import CcinnBucketKit
import Foundation
import Testing

@Suite("Window requests")
struct WindowRequestTests {
    @Test("every request opens its own window")
    func everyRequestIsUnique() {
        let account = UUID()
        // SwiftUI brings an existing window to the front when the value is equal, so two requests for the same
        // account must differ.
        #expect(WindowRequest(accountID: account) != WindowRequest(accountID: account))
        #expect(WindowRequest(accountID: account).accountID == account)
    }

    @Test("round-trips through Codable")
    func roundTripsThroughCodable() throws {
        let request = WindowRequest(accountID: UUID())
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test("decodes without the nonce")
    func decodesWithoutTheNonce() throws {
        let account = UUID()
        let decoded = try JSONDecoder().decode(WindowRequest.self, from: Data(#"{"accountID":"\#(account.uuidString)"}"#.utf8))
        #expect(decoded.accountID == account)
    }

    @Test("encodes ids only")
    func encodesIDsOnly() throws {
        // SwiftUI may persist the value for window restoration; it must never carry anything but ids.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WindowRequest(accountID: UUID()))) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["accountID", "nonce"])
    }
}
