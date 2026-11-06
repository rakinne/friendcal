import Foundation
import Observation
import FriendCalCore

/// A group member as Home shows them: initials face, online dot, active arc.
struct HomeMember: Identifiable, Equatable {
    let id: UUID
    let name: String
    var isOnline: Bool
    var isActive: Bool

    /// "Sam" -> "SA", "Ana Ruiz" -> "AR".
    var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(name.prefix(2)).uppercased()
    }
}

/// Home screen state. Heatmap numbers, chips and Share all derive from HeatmapBuilder (X2);
/// selection follows the visible week (X6, X10).
@Observable
final class HomeModel {
    let groupName: String
    let calendar: Calendar
    var isLoading: Bool
    var members: [HomeMember]
    var proposal: Proposal?
    var slots: [AvailabilitySlot]
    var lastUpdated: Date

    private(set) var weeks: [HeatmapWeek] = []
    private(set) var visibleWeekID: Date?
    private(set) var selectedCellID: HeatmapCell.ID?

    init(fixture: HomeFixture, now: Date = .now, calendar: Calendar = .current) {
        groupName = fixture.groupName
        self.calendar = calendar
        isLoading = fixture.isLoading
        members = fixture.members
        proposal = fixture.proposal
        slots = fixture.slots
        lastUpdated = fixture.lastUpdated
        refresh(now: now)
    }

    /// Recounts with a fresh `now`, so holds that expired while Home stayed open drop out of the
    /// counts, roster, best badge and share text with no new data (X12). Keeps the visible week
    /// when it still exists and re-resolves the selection (X6, X10). HomeView calls this every
    /// minute and when the scene becomes active. `lastUpdated` is untouched: it tracks data
    /// changes, not recounts.
    func refresh(now: Date) {
        guard let p = proposal else {
            weeks = []; visibleWeekID = nil; selectedCellID = nil
            return
        }
        weeks = HeatmapBuilder.weeks(slots: slots, window: p.window, recipientIDs: p.distribution.recipientIDs,
                                     proposalID: p.id, now: now, calendar: calendar)
        if !weeks.contains(where: { $0.id == visibleWeekID }) { visibleWeekID = weeks.first?.id }
        selectedCellID = HeatmapSelection.resolve(current: selectedCellID, week: visibleWeek)
    }

    func showWeek(_ id: Date?) {
        guard let id, id != visibleWeekID, weeks.contains(where: { $0.id == id }) else { return }
        visibleWeekID = id
        selectedCellID = HeatmapSelection.resolve(current: selectedCellID, week: visibleWeek)
    }

    /// Only enabled cells of the visible week are selectable (D22).
    func select(_ id: HeatmapCell.ID) {
        guard visibleWeek?.cells.contains(where: { $0.id == id && $0.isEnabled }) == true else { return }
        selectedCellID = id
    }

    var visibleWeek: HeatmapWeek? { weeks.first { $0.id == visibleWeekID } }
    var selectedCell: HeatmapCell? { visibleWeek?.cells.first { $0.id == selectedCellID } }
    var total: Int { proposal?.distribution.recipientIDs.count ?? 0 }
    var onlineCount: Int { members.filter(\.isOnline).count }

    var shareText: String? {
        guard let cell = selectedCell, let p = proposal else { return nil }
        return ShareText.format(title: p.title, cell: cell, calendar: calendar, locale: .current)
    }

    /// VoiceOver hint when Share is disabled (X6, X10).
    var shareDisabledHint: String? {
        if selectedCell == nil { return "Pick a time first" }
        return HeatmapSelection.canShare(selectedCell) ? nil : "Nobody shares an hour here yet"
    }

    /// Wheel faces (D36): up to 10 members; past 10, 9 faces (the active friend always among them)
    /// and a "+N" face for the rest.
    var wheel: (faces: [HomeMember], overflow: Int) {
        guard members.count > 10 else { return (members, 0) }
        var faces = Array(members.prefix(9))
        if let active = members.first(where: \.isActive), !faces.contains(active) { faces[8] = active }
        return (faces, members.count - 9)
    }

    /// The selected cell's statuses, in member order; nil hides the chips (D19) and strips status
    /// from the drawer (X11).
    var chips: [(member: HomeMember, status: CellStatus)]? {
        guard let roster = selectedCell?.roster, !roster.isEmpty else { return nil }
        return members.compactMap { m in roster[m.id].map { (m, $0) } }
    }
}
