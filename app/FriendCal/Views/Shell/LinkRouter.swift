import SwiftUI
import UIKit
import Observation
import FriendCalCore

/// The one owner of every opened link, attached at `RootGateView` ABOVE sign-in (spec 5, "Link router").
/// It receives each URL, parses it once and keeps the pending link on the device; the shell reads it
/// once someone is signed in. It replaces the replay code in `FriendCalApp` that never worked, because
/// nothing ever stored the link it tried to replay.
///
/// The rules (one pending link, newest wins, generation numbers, cleared when answered) are
/// `LinkRouterState`'s, in the fast lane; this class adds storage and observation.
///
/// Launch arguments (DEBUG): `-FriendCalPendingLink none` starts with nothing pending and clears the
/// stored value; `-FriendCalPendingLink <url>` pins that link as pending; `-FriendCalPendingLink
/// stored` restores whatever the last launch stored (relaunch tests). With no argument a demo or UI
/// test launch (in-memory store, a fixture) starts clean so one test's link cannot leak into the next,
/// and a real launch restores the stored link.
@MainActor
@Observable
final class LinkRouter {
    static let storageKey = "FriendCalPendingLinkStored"

    private(set) var state: LinkRouterState
    /// Bumped for every URL that was not a FriendCal link; the shell toasts once per bump.
    private(set) var invalidCount = 0
    @ObservationIgnored private let defaults: UserDefaults

    var pending: DeepLink? { state.pending }
    var generation: Int { state.generation }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.storageKey).flatMap(URL.init(string:))
        var restoring: URL? = stored
        var pinned: URL?
        #if DEBUG
        let argument = defaults.string(forKey: "FriendCalPendingLink")
        let isDemo = defaults.string(forKey: "FriendCalStore") == "memory" || defaults.string(forKey: "FriendCalFixture") != nil
        switch argument {
        case "none": restoring = nil
        case "stored": break
        case .some(let text): pinned = URL(string: text); restoring = nil
        case nil: if isDemo { restoring = nil }
        }
        #endif
        state = LinkRouterState(restoring: restoring)
        if let pinned { state.open(pinned) }
        persist()
    }

    /// Every URL the system hands the app.
    func open(_ url: URL) {
        if case .invalid = state.open(url) { invalidCount += 1 }
        persist()
    }

    /// The link under `generation` was answered. Never clears a newer link.
    func finish(generation: Int) {
        if state.finish(generation: generation) { persist() }
    }

    /// "Not now", sign-out, account deletion.
    func clear() {
        state.clear()
        persist()
    }

    private func persist() {
        if let url = state.storedURL {
            defaults.set(url.absoluteString, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }
}

/// Waits until nothing is presented over the app, so Accept can appear after a sheet closes instead of
/// dismissing it (spec 4.3). The sheets belong to a dozen different views, so asking each one is not
/// an option; the view controller hierarchy is the one place that knows.
@MainActor
enum PresentationGate {
    static func isClear() -> Bool {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return true }
        var top = root
        while let next = top.presentedViewController {
            if next.isBeingDismissed { return true }
            top = next
        }
        return top === root
    }

    /// Returns when nothing is presented, or false if the task was cancelled first.
    static func waitUntilClear() async -> Bool {
        while !isClear() {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return !Task.isCancelled
    }
}
