import CcinnBucketKit
import Foundation
import Testing

@MainActor
@Suite("Window handoff")
struct WindowHandoffTests {
    @Test("a payload is taken once")
    func takenOnce() {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(for: UUID(), payload: "credentials")
        #expect(handoff.take(request) == "credentials")
        // Each handoff connects exactly one window; nothing stays behind in memory.
        #expect(handoff.take(request) == nil)
    }

    @Test("a request this process did not make has no payload")
    func unknownRequest() throws {
        let handoff = WindowHandoff<String>()
        // A window macOS restores carries a request decoded from a previous run.
        let restored = try JSONDecoder().decode(WindowRequest.self, from: JSONEncoder().encode(WindowRequest(accountID: UUID())))
        #expect(handoff.take(restored) == nil)
    }

    @Test("two requests for the same account are independent")
    func sameAccountTwice() {
        let handoff = WindowHandoff<String>()
        let account = UUID()
        let first = handoff.request(for: account, payload: "first")
        let second = handoff.request(for: account, payload: "second")
        #expect(first != second)
        #expect(first.accountID == account && second.accountID == account)
        #expect(handoff.take(second) == "second")
        #expect(handoff.take(first) == "first")
    }

    @Test("a request matches by account and nonce")
    func matchesWholeRequest() {
        let handoff = WindowHandoff<String>()
        let request = handoff.request(for: UUID(), payload: "payload")
        var otherAccount = request
        otherAccount.accountID = UUID()
        #expect(handoff.take(otherAccount) == nil)
        #expect(handoff.take(request) == "payload")
    }
}
