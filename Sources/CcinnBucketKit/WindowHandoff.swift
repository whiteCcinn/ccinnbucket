import Foundation

/// Passes what a new window needs (for example an account and its credentials) from the window that opened it.
///
/// A `WindowRequest` carries ids only, because SwiftUI may persist it; the payload stays here, in memory, until the
/// new window takes it. Only requests made by this process have a payload, so a window that macOS restores from a
/// previous run finds nothing and never connects on its own.
@MainActor
public final class WindowHandoff<Payload> {
    private var pending: [WindowRequest: Payload] = [:]

    public init() {}

    /// A new, unique request for a window about `accountID`, holding `payload` until that window takes it.
    public func request(for accountID: UUID, payload: Payload) -> WindowRequest {
        let request = WindowRequest(accountID: accountID)
        pending[request] = payload
        return request
    }

    /// Removes and returns the payload of a request made by this handoff; `nil` for any other request or a second take.
    public func take(_ request: WindowRequest) -> Payload? {
        pending.removeValue(forKey: request)
    }
}
