import Foundation
import Observation

/// The Accept screen's state machine (spec 4.3), in the fast lane. The view draws `phase` and calls
/// `check()` and `connect()`; every rule about what a retry means is here.
///
///     checking ──valid──> ready ──connect──> connecting ──valid/already──> (connected)
///        │                 ▲                     │
///        │ fails           └────────Retry────────┴── fails ──> connectFailed
///        ├─dead──> dead        own ──> own        already ──> already
///        └─ fails ──> checkFailed ──Retry──> checking
///
/// Opening the link calls NOTHING but preview until `connect()`. The name shown is the one the server
/// returned, never the hint in the URL.
@MainActor
@Observable
public final class FriendAcceptFlow {
    public enum Phase: Equatable {
        case checking
        /// The preview failed (network); the link is kept and Retry checks again.
        case checkFailed(UserFacingError)
        case ready(Friend)
        case connecting(Friend)
        /// Connect failed (network); the link is kept and Retry connects again.
        case connectFailed(Friend, UserFacingError)
        /// "This link doesn't work anymore." No name, no reason.
        case dead
        /// "This is your link" and "Share it".
        case own
        /// "You and Sam are already connected" and "Open Groups".
        case already(Friend)
    }

    public private(set) var phase: Phase = .checking
    public let token: String

    private let store: ProposalStore
    private let willConnect: (UUID) -> Void
    private var inFlight = false

    /// `willConnect` runs with the inviter's id just BEFORE the accept call, so the roster can mark
    /// them known: the person who taps Connect is never told about the friend they just made.
    public init(store: ProposalStore, token: String, willConnect: @escaping (UUID) -> Void = { _ in }) {
        self.store = store
        self.token = token
        self.willConnect = willConnect
    }

    public func check() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        phase = .checking
        do {
            let answer = try await store.previewFriendLink(token: token)
            phase = Self.phase(for: answer)
        } catch {
            phase = .checkFailed(UserFacingError.map(error, action: .previewFriend))
        }
    }

    /// Returns the new friend when the connection is made. A repeat that the server answers `already`
    /// counts as made: a retry after a lost reply must not strand someone on a failure.
    @discardableResult
    public func connect() async -> Friend? {
        guard !inFlight else { return nil }   // a double tap is one call
        let friend: Friend
        switch phase {
        case .ready(let f), .connectFailed(let f, _): friend = f
        default: return nil
        }
        inFlight = true
        defer { inFlight = false }
        phase = .connecting(friend)
        willConnect(friend.id)
        do {
            let answer = try await store.acceptFriendLink(token: token)
            switch answer.status {
            case .valid, .already:
                return answer.person ?? friend
            case .own:
                phase = .own
            case .dead:
                phase = .dead
            }
            return nil
        } catch {
            phase = .connectFailed(friend, UserFacingError.map(error, action: .acceptFriend))
            return nil
        }
    }

    private static func phase(for answer: FriendLinkAnswer) -> Phase {
        switch answer.status {
        case .valid: return answer.person.map(Phase.ready) ?? .dead
        case .already: return answer.person.map(Phase.already) ?? .dead
        case .own: return .own
        case .dead: return .dead
        }
    }
}
