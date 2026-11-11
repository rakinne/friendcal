import Foundation

/// The rules of the one place that owns every opened link (`LinkRouter` in the app, attached above
/// sign-in). A value type, so the fast lane covers the hard part: which link is pending, and which
/// generation may clear it.
///
///   - ONE pending link at a time; the most recently opened wins.
///   - Each carries a generation number. Finishing an older one (a slow join that comes back after a
///     newer link arrived) never clears the newer one.
///   - It is stored on the device (`storedURL`), so it survives a cancelled sign-in and a relaunch.
///   - Cleared when answered, on "Not now", on sign-out and on account deletion.
public struct LinkRouterState: Equatable, Sendable {
    public enum Opened: Equatable, Sendable {
        /// A link we understand is now pending, under this generation.
        case pending(generation: Int)
        /// Not a FriendCal link. Nothing changed; the screen toasts "That link isn't a FriendCal invite".
        case invalid
    }

    public private(set) var pending: DeepLink?
    public private(set) var generation = 0

    public init(restoring stored: URL? = nil) {
        if let stored, let link = DeepLink.parse(stored) {
            pending = link
            generation = 1
        }
    }

    /// The link to write to device storage, or nil when nothing is pending. Always the custom-scheme
    /// form: it carries everything the pending link needs.
    public var storedURL: URL? { pending?.url }

    @discardableResult
    public mutating func open(_ url: URL) -> Opened {
        guard let link = DeepLink.parse(url) else { return .invalid }
        generation += 1
        pending = link
        return .pending(generation: generation)
    }

    /// The link under `generation` was answered. A no-op when a newer link has replaced it.
    /// Returns whether it cleared anything.
    @discardableResult
    public mutating func finish(generation finished: Int) -> Bool {
        guard finished == generation, pending != nil else { return false }
        pending = nil
        return true
    }

    /// "Not now", sign-out, account deletion: nothing stays pending. The generation keeps counting,
    /// so an operation still in flight for the old link cannot match a later one.
    public mutating func clear() {
        generation += 1
        pending = nil
    }
}
