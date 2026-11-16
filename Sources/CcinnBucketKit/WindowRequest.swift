import Foundation

/// Asks for a new window that connects to an account right away. Every window has its own connection;
/// the nonce makes each request unique, because SwiftUI brings an existing window to the front instead of opening
/// a new one when the requested value is equal. SwiftUI may persist the value, so it carries ids only, never secrets.
public struct WindowRequest: Codable, Hashable, Sendable {
    public var accountID: UUID
    public var nonce: UUID

    public init(accountID: UUID) {
        self.accountID = accountID
        nonce = UUID()
    }

    private enum CodingKeys: String, CodingKey { case accountID, nonce }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(UUID.self, forKey: .accountID)
        nonce = try container.decodeIfPresent(UUID.self, forKey: .nonce) ?? UUID()
    }
}
