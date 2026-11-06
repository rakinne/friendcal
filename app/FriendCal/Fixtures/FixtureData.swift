import Foundation
import FriendCalCore

/// One Home state for previews, UI tests and demos (D19). Fixtures supply members and slots only,
/// never chips or counts: every number on Home comes from HeatmapBuilder (X2).
enum FixtureScenario: String, CaseIterable {
    case populated     // 15 members, 2 weeks, best Sat afternoon 13 of 15
    case loading       // custom skeletons in every module
    case noFriends     // empty wheel, no proposal
    case fewFriends    // 3 members: faces evenly spaced, no arcs
    case noProposal    // members, but "No plans brewing"
    case zeroOverlap   // proposal with no slots: "No overlap yet. Nudge your crew."
    case singleWeek    // one week, page dots hidden
    case stale         // populated, last updated 6 min before launch

    /// `-FriendCalFixture <name>` on the launch arguments (UI tests); populated otherwise.
    static var fromLaunchArguments: FixtureScenario {
        UserDefaults.standard.string(forKey: "FriendCalFixture").flatMap(FixtureScenario.init(rawValue:)) ?? .populated
    }
}

struct HomeFixture {
    var groupName: String
    var members: [HomeMember]
    var proposal: Proposal?
    var slots: [AvailabilitySlot]
    var lastUpdated: Date
    var isLoading = false
}

enum FixtureData {
    /// Monday 2026-11-09, the week the approved mockup shows ("Nov 9–15"). Dates are fixed so
    /// screenshots are comparable run to run; hours are local, so the grid reads the same in any timezone.
    static let weekOne = DateComponents(year: 2026, month: 11, day: 9)

    /// 15 initials-only friends (no photos of real people), most recently active first.
    /// The first 10 are online; Leo is the active friend (the coral arc).
    static let members: [HomeMember] = [
        "Sam", "Maya", "Leo", "Nina", "Arlo", "Mika", "Rosa", "Dev", "Theo", "Cleo",
        "Ines", "Jun", "Kai", "Omar", "Pia",
    ].enumerated().map { i, name in
        HomeMember(id: fixtureID(i + 1), name: name, isOnline: i < 10, isActive: name == "Leo")
    }

    /// commonCount per cell, [week][daypart][day Mon...Sun]; nil = outside the window.
    /// Week 1 matches the approved mockup; the window opens Monday 17:00.
    static let grid: [[[Int?]]] = [
        [[nil, 3, 3, 7, 5, 6, 5], [nil, 9, 8, 9, 10, 13, 9], [3, 6, 8, 6, 4, 7, 3]],
        [[4, 2, 5, 6, 8, 11, 9], [6, 5, 7, 8, 9, 10, 7], [5, 7, 6, 9, 12, 8, 4]],
    ]

    static func make(_ scenario: FixtureScenario, now: Date = .now, calendar: Calendar = .current) -> HomeFixture {
        let group = "Brunch crew"
        switch scenario {
        case .loading:
            return HomeFixture(groupName: group, members: [], proposal: nil, slots: [], lastUpdated: now, isLoading: true)
        case .noFriends:
            return HomeFixture(groupName: group, members: [], proposal: nil, slots: [], lastUpdated: now)
        case .noProposal:
            return HomeFixture(groupName: group, members: members, proposal: nil, slots: [], lastUpdated: now)
        case .zeroOverlap:
            return HomeFixture(groupName: group, members: members, proposal: proposal(to: members, weeks: 2, calendar: calendar), slots: [], lastUpdated: now)
        case .fewFriends:
            let few = Array(members.prefix(3))
            return populated(group: group, members: few, weeks: 2, now: now, calendar: calendar)
        case .singleWeek:
            return populated(group: group, members: members, weeks: 1, now: now, calendar: calendar)
        case .stale:
            var f = populated(group: group, members: members, weeks: 2, now: now, calendar: calendar)
            f.lastUpdated = now.addingTimeInterval(-6 * 60)
            return f
        case .populated:
            return populated(group: group, members: members, weeks: 2, now: now, calendar: calendar)
        }
    }

    static func fixtureID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    // MARK: Builders

    private static let proposalID = fixtureID(900)

    private static func monday(_ calendar: Calendar) -> Date { calendar.date(from: weekOne)! }

    private static func proposal(to members: [HomeMember], weeks: Int, calendar: Calendar) -> Proposal {
        let mon = monday(calendar)
        let lower = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: mon)!
        let upper = calendar.date(byAdding: .day, value: 7 * weeks, to: mon)!
        return Proposal(id: proposalID, title: "Brunch", window: DateRange(lower: lower, upper: upper),
                        createdBy: members.first?.id ?? fixtureID(0),
                        distribution: Distribution(mode: .newGroup, recipientIDs: members.map(\.id)))
    }

    private static func populated(group: String, members: [HomeMember], weeks: Int, now: Date, calendar: Calendar) -> HomeFixture {
        let p = proposal(to: members, weeks: weeks, calendar: calendar)
        return HomeFixture(groupName: group, members: members, proposal: p, slots: slots(for: p, members: members, weeks: weeks, calendar: calendar), lastUpdated: now)
    }

    /// Per cell with count n: n members get a slot covering the whole daypart (so commonCount = n);
    /// of the rest, one gets a 30-min slot at the start (maybe), one a 45-min slot two hours in
    /// (after N) when at least three are left, and the others nothing (busy). Both short slots are
    /// under 60 min, so they never change the common window.
    private static func slots(for proposal: Proposal, members: [HomeMember], weeks: Int, calendar: Calendar) -> [AvailabilitySlot] {
        let mon = monday(calendar)
        var out: [AvailabilitySlot] = []
        func add(_ member: HomeMember, _ from: Date, _ minutes: Int) {
            out.append(AvailabilitySlot(id: fixtureID(1000 + out.count), userID: member.id,
                                        range: DateRange(lower: from, upper: from.addingTimeInterval(Double(minutes) * 60)),
                                        sourceProposalID: proposal.id, state: .softHold, createdAt: mon))
        }
        for week in 0..<weeks {
            for (partIndex, part) in Daypart.allCases.enumerated() {
                for dayIndex in 0..<7 {
                    guard let count = grid[week][partIndex][dayIndex] else { continue }
                    let day = calendar.date(byAdding: .day, value: week * 7 + dayIndex, to: mon)!
                    let start = calendar.date(bySettingHour: part.hours.start, minute: 0, second: 0, of: day)!
                    let end = calendar.date(bySettingHour: part.hours.end, minute: 0, second: 0, of: day)!
                    let order = ordering(members, week: week, part: part, dayIndex: dayIndex)
                    let n = min(count, order.count)
                    for m in order.prefix(n) { add(m, start, Int(end.timeIntervalSince(start) / 60)) }
                    let rest = Array(order.dropFirst(n))
                    if let maybe = rest.first { add(maybe, start, 30) }
                    if rest.count >= 3 { add(rest[1], start.addingTimeInterval(2 * 3600), 45) }
                }
            }
        }
        return out
    }

    /// Who is free where. The best cell (Sat afternoon, week 1) leaves out Maya (maybe) and Nina
    /// (busy) so the first chips match the mockup; other cells rotate through the group.
    private static func ordering(_ members: [HomeMember], week: Int, part: Daypart, dayIndex: Int) -> [HomeMember] {
        if week == 0, part == .afternoon, dayIndex == 5, members.count == 15 {
            let out = members.filter { $0.name != "Maya" && $0.name != "Nina" }
            return out + members.filter { $0.name == "Maya" } + members.filter { $0.name == "Nina" }
        }
        guard !members.isEmpty else { return [] }
        let shift = (week * 21 + part.rawValue * 7 + dayIndex) * 4 % members.count
        return Array(members[shift...] + members[..<shift])
    }
}
