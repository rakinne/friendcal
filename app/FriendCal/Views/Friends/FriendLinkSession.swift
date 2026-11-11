import SwiftUI
import Observation
import FriendCalCore

/// The link's token, remembered per account so the sheet opens with it at once (spec 4.1). Cleared on
/// sign-out and account deletion. Persistent only on the network store: a demo or UI-test launch keeps
/// it in memory, so one test's link cannot be "cached" into the next.
@MainActor
final class FriendLinkCache {
    private let defaults: UserDefaults?
    private var memory: [UUID: String] = [:]

    init(persistent: Bool) { defaults = persistent ? .standard : nil }

    private func key(_ account: UUID) -> String { "FriendCalFriendLink.\(account.uuidString)" }

    func token(for account: UUID) -> String? {
        memory[account] ?? defaults?.string(forKey: key(account)).flatMap { FriendToken.isValid($0) ? $0 : nil }
    }

    func set(_ token: String, for account: UUID) {
        memory[account] = token
        defaults?.set(token, forKey: key(account))
    }

    func clear(account: UUID) {
        memory[account] = nil
        defaults?.removeObject(forKey: key(account))
    }
}

/// The Add a friend sheet's state, and the QR screen's (they show one link). Server-first: nothing is
/// shown as a new link until the server returned it.
///
///     open ──cached? show it at once──> refresh behind it
///          └─nothing cached──> skeleton ──> ready | failed(Retry)
///     Reset ─confirm─> resetting ──> ready (+ "New link ready")
///                          └─fails─> re-read the link before anything is enabled; if that fails too,
///                                    stay disabled with Retry
@MainActor
@Observable
final class FriendLinkSession: Identifiable {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    enum Phase: Equatable {
        case loading
        case ready(String)
        case failed(UserFacingError)
    }

    private(set) var phase: Phase = .loading
    private(set) var isResetting = false
    /// A reset that failed shows its sentence until the link is read again.
    private(set) var resetError: UserFacingError?
    /// Set for a moment after a successful reset; the sheet shows "New link ready".
    private(set) var resetCount = 0

    let senderName: String
    private let store: ProposalStore
    private let account: UUID
    private let cache: FriendLinkCache

    init(store: ProposalStore, account: UUID, senderName: String, cache: FriendLinkCache) {
        self.store = store
        self.account = account
        self.senderName = senderName
        self.cache = cache
        if let cached = cache.token(for: account) { phase = .ready(cached) }
    }

    var token: String? {
        if case .ready(let token) = phase { return token }
        return nil
    }

    /// Share, Copy and QR need a usable link and no reset in flight.
    var isUsable: Bool { token != nil && !isResetting }

    /// What is shared and copied: the link with the sender's name as a hint, in the form the build shares.
    var shareURL: URL? { token.map { DeepLink.friend($0, name: senderName).shareURL } }

    var shareText: String? { shareURL.map { ShareText.friendLink(name: senderName, url: $0) } }

    /// Opening the sheet, and Retry. A cached link stays on screen while the read happens behind it;
    /// a failed refresh of a cached link leaves the cached one in place.
    func load() async {
        let hadCache = token != nil
        if !hadCache { phase = .loading }
        do {
            let fresh = try await store.friendLink()
            cache.set(fresh, for: account)
            phase = .ready(fresh)
        } catch {
            if !hadCache { phase = .failed(UserFacingError.map(error, action: .friendLink)) }
        }
    }

    func reset() async {
        guard !isResetting else { return }
        isResetting = true
        resetError = nil
        defer { isResetting = false }
        do {
            let fresh = try await store.resetFriendLink()
            cache.set(fresh, for: account)
            phase = .ready(fresh)
            resetCount += 1
        } catch {
            resetError = UserFacingError.map(error, action: .resetFriendLink)
            // Whether the reset applied is unknown (the reply may have been lost). Nothing is enabled
            // until the link is read again, so the sheet can never show or share a dead token.
            phase = .loading
            do {
                let current = try await store.friendLink()
                cache.set(current, for: account)
                phase = .ready(current)
            } catch {
                phase = .failed(UserFacingError.map(error, action: .friendLink))
            }
        }
    }
}
