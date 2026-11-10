import Foundation
import Observation
import FriendCalCore

/// Everything Groups shows, as one observable value (variant D). Statuses, crews and busy time live
/// here in memory: nothing on this screen reaches the network store yet, so a status you set stays on
/// this device until the backend (a statuses table with its own RLS) lands. All copy and rules come
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
    private(set) var crews: [Crew]
    private(set) var statuses: [UUID: FriendStatus]
    private let busyNow: Set<UUID>
    private let busyBlocks: [UUID: [DateInterval]]
    /// Folder ids the user collapsed.
    var collapsed: Set<String> = []

    let clock: () -> Date
    let calendar: Calendar

    init(seed: Seed, now: @escaping () -> Date = { .now }, calendar: Calendar = .current) {
        you = seed.you
        friends = seed.friends
        crews = seed.crews
        statuses = seed.statuses
        busyNow = seed.busyNow
        busyBlocks = seed.busyBlocks
        clock = now
        self.calendar = calendar
    }

    var now: Date { clock() }

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
