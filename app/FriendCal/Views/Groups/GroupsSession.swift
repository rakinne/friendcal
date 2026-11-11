import Foundation
import Observation
import SwiftUI
import FriendCalCore

/// The saved set of friend ids already seen, per account (`FriendRoster.knownIDs`). nil means "never
/// loaded for this account", which is different from an empty set. Persistent on the network store
/// only: a demo or UI-test launch keeps it in memory, so one test's friends cannot make the next
/// test's first friend silent.
@MainActor
final class KnownFriendsStore {
    private let defaults: UserDefaults?
    private var memory: [UUID: Set<UUID>] = [:]

    init(persistent: Bool) { defaults = persistent ? .standard : nil }

    private func key(_ account: UUID) -> String { "FriendCalKnownFriends.\(account.uuidString)" }

    func load(_ account: UUID) -> Set<UUID>? {
        if let known = memory[account] { return known }
        guard let strings = defaults?.stringArray(forKey: key(account)) else { return nil }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    func save(_ ids: Set<UUID>?, for account: UUID) {
        memory[account] = ids
        if let ids { defaults?.set(ids.map(\.uuidString).sorted(), forKey: key(account)) } else { defaults?.removeObject(forKey: key(account)) }
    }
}

/// Everything Groups shows, as one observable value (variant D). Statuses, crews and busy time live
/// here in memory: nothing on this screen reaches the network store yet, so a status you set stays on
/// this device until the backend (a statuses table with its own RLS) lands. The ROSTER is different:
/// who your friends are comes from the store (`friends()`), through `FriendRoster`, which owns the rules
/// (stale reads, what counts as new); this class holds the state and animates around it. All copy and rules come
/// from FriendCalCore (`Presence`, `MomentsEngine`, `GroupsLayout`, `CrewDraft`), which is what the
/// unit tests cover; this class only holds state and hands the views what they need.
@MainActor
@Observable
final class GroupsSession {
    struct Seed {
        var you: Buddy
        var friends: [Buddy]
        var crews: [Crew]
        var statuses: [UUID: FriendStatus] = [:]
        var busyNow: Set<UUID> = []
        var busyBlocks: [UUID: [DateInterval]] = [:]
    }

    let you: Buddy
    private(set) var friends: [Buddy]
    private let store: ProposalStore?
    private let knownStore: KnownFriendsStore
    private(set) var roster: FriendRoster
    /// A first load that failed: shown with Retry, never as "no friends".
    private(set) var loadError: UserFacingError?
    /// Friends being removed: their rows dim until the server answers.
    private(set) var removing: Set<UUID> = []
    /// Rows highlighted for two seconds after a connection.
    private(set) var highlighted: Set<UUID> = []
    /// The Moments line while a connection is being celebrated.
    private(set) var arrivalNote: String?
    /// Bumps once per celebration: the screen's success haptic follows it.
    private(set) var celebrations = 0
    private var isOnScreen = false
    private var isRefreshing = false
    private var refreshAgain = false
    private var highlightTask: Task<Void, Never>?
    private(set) var crews: [Crew]
    private(set) var statuses: [UUID: FriendStatus]
    private let busyNow: Set<UUID>
    private let busyBlocks: [UUID: [DateInterval]]
    /// Folder ids the user collapsed.
    var collapsed: Set<String> = []

    let clock: () -> Date
    let calendar: Calendar

    init(seed: Seed, store: ProposalStore? = nil, knownStore: KnownFriendsStore? = nil,
         now: @escaping () -> Date = { .now }, calendar: Calendar = .current) {
        you = seed.you
        self.store = store
        let knownStore = knownStore ?? KnownFriendsStore(persistent: false)
        self.knownStore = knownStore
        roster = FriendRoster(friends: seed.friends.map { Friend(id: $0.id, name: $0.name) },
                              knownIDs: knownStore.load(seed.you.id))
        friends = seed.friends
        crews = seed.crews
        statuses = seed.statuses
        busyNow = seed.busyNow
        busyBlocks = seed.busyBlocks
        clock = now
        self.calendar = calendar
    }

    var now: Date { clock() }

    // MARK: Roster (from the store)

    /// The first read is still out: nothing is drawn as "no friends" yet.
    var isLoadingRoster: Bool { store != nil && !roster.hasLoaded && friends.isEmpty && loadError == nil }

    /// Friends who arrived and have not been announced: the Groups tab's dot while another tab is up.
    var arrivalCount: Int { isOnScreen ? 0 : roster.arrivals.count }

    /// Reads the roster. A failure leaves the last roster on screen and retries on the next foreground;
    /// only a failed FIRST load shows an error. A read that began before a local accept or remove is
    /// discarded by the roster.
    func refresh() async {
        guard store != nil else { return }
        // Concurrent callers (the shell, the screen, a foreground) coalesce into one read, and one
        // more read follows if somebody asked while it was out.
        if isRefreshing { refreshAgain = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        // A failed read does not loop: the error stands until the next foreground or a Retry.
        var succeeded = true
        repeat {
            refreshAgain = false
            succeeded = await readRoster()
        } while refreshAgain && succeeded && !Task.isCancelled
    }

    private func readRoster() async -> Bool {
        guard let store else { return true }
        let generation = roster.beginRefresh()
        do {
            let loaded = try await store.friends()
            guard roster.apply(loaded, startedAt: generation) else { return true }
            loadError = nil
            syncFriends()
            knownStore.save(roster.knownIDs, for: you.id)
            announceArrivalsIfVisible()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !roster.hasLoaded { loadError = UserFacingError.map(error, action: .loadFriends) }
            return false
        }
    }

    /// Groups is on screen (or not). Arrivals are announced only while it is.
    func setOnScreen(_ visible: Bool) {
        isOnScreen = visible
        if visible { announceArrivalsIfVisible() }
    }

    /// The recipient tapped Connect: the inviter is no "arrival" for the person who made them.
    func willConnect(_ id: UUID) {
        roster.markKnown(id)
        knownStore.save(roster.knownIDs, for: you.id)
    }

    /// The recipient connected: show the friend at once, highlight them, and say so.
    func connected(_ friend: Friend) {
        roster.insertLocally(friend)
        syncFriends()
        knownStore.save(roster.knownIDs, for: you.id)
        celebrate([friend], note: "You and \(friend.name) are connected")
        Task { await refresh() }
    }

    /// Removes a friend. nil on success; the mapped sentence on failure, with the row back as it was.
    func remove(_ buddy: Buddy) async -> UserFacingError? {
        guard let store else { return nil }
        removing.insert(buddy.id)
        defer { removing.remove(buddy.id) }
        do {
            try await store.removeFriend(buddy.id)
            roster.removeLocally(buddy.id)
            syncFriends()
            knownStore.save(roster.knownIDs, for: you.id)
            return nil
        } catch {
            return UserFacingError.map(error, action: .removeFriend)
        }
    }

    private func syncFriends() {
        let online = Dictionary(friends.map { ($0.id, $0.isOnline) }, uniquingKeysWith: { first, _ in first })
        friends = roster.friends.map { Buddy(id: $0.id, name: $0.name, isOnline: online[$0.id] ?? true) }
    }

    private func announceArrivalsIfVisible() {
        guard isOnScreen else { return }
        let arrived = roster.takeArrivals()
        guard !arrived.isEmpty else { return }
        knownStore.save(roster.knownIDs, for: you.id)
        celebrate(arrived, note: FriendRoster.arrivalText(arrived))
    }

    /// Moments line, haptic, VoiceOver and a two-second row highlight.
    private func celebrate(_ friends: [Friend], note: String?) {
        arrivalNote = note
        highlighted = Set(friends.map(\.id))
        celebrations += 1
        if let note { AccessibilityNotification.Announcement(note).post() }
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            // Two seconds (UI tests lengthen it with -FriendCalToastSeconds, like toasts).
            try? await Task.sleep(for: .seconds(max(2, ToastCenter.displaySeconds > 2.5 ? ToastCenter.displaySeconds : 2)))
            guard !Task.isCancelled else { return }
            self?.highlighted = []
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.arrivalNote = nil
        }
    }

    // MARK: Reading

    var folders: [GroupsFolder] { GroupsLayout.folders(crews: crews, friends: friends) }

    func presence(of id: UUID) -> Presence {
        Presence.resolve(status: statuses[id], isBusy: busyNow.contains(id), now: now)
    }

    var myPresence: Presence { presence(of: you.id) }

    func buddy(_ id: UUID) -> Buddy? { id == you.id ? you : friends.first { $0.id == id } }

    func rowText(for buddy: Buddy) -> RowText {
        presence(of: buddy.id).rowText(name: buddy.name, isYou: buddy.id == you.id, now: now, calendar: calendar)
    }

    /// The viewer counts as free with no live status (or "free") and no busy time of their own.
    var moment: Moment {
        if let arrivalNote { return Moment(text: arrivalNote, detail: nil, action: nil) }
        let mine = myPresence
        let free: Bool
        switch mine {
        case .quiet: free = !busyNow.contains(you.id)
        case .busy: free = false
        case .status(let s): free = s.kind == .free
        }
        return MomentsEngine.moment(friends: friends, presence: { self.presence(of: $0) }, viewerFree: free,
                                    viewerHasStatus: mine.status != nil, now: now, calendar: calendar)
    }

    func ribbon(for id: UUID) -> [RibbonSegment] {
        DayRibbon.segments(status: presence(of: id).status, busy: busyBlocks[id] ?? [], now: now, calendar: calendar)
    }

    func isExpanded(_ folder: GroupsFolder) -> Bool { !collapsed.contains(folder.id) }

    func toggle(_ folder: GroupsFolder) {
        if collapsed.contains(folder.id) { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
    }

    // MARK: Writing (in memory)

    /// Sets your own status from the sheet. Returns what was stored.
    @discardableResult
    func setMyStatus(kind: StatusKind, message: String, duration: StatusDuration) -> FriendStatus {
        let status = FriendStatus(kind: kind, message: message, since: now, until: duration.end(from: now, calendar: calendar))
        statuses[you.id] = status
        return status
    }

    func clearMyStatus() { statuses[you.id] = nil }

    /// Makes a crew from the ticked friends and returns it.
    @discardableResult
    func createCrew(_ draft: CrewDraft) -> Crew? {
        guard draft.canCreate else { return nil }
        let crew = Crew(name: draft.resolvedName(among: friends), memberIDs: draft.selected)
        crews.append(crew)
        return crew
    }
}
