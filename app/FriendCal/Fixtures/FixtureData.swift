import Foundation
import FriendCalCore

/// One app state for previews, UI tests and demos (D19). Fixtures supply members and slots only,
/// never chips or counts: every number on Home and the invite comes from HeatmapBuilder and
/// LockState (X2). Issue #5 adds the invite scenarios; every scenario seeds an `InMemoryProposalStore`.
enum FixtureScenario: String, CaseIterable {
    case populated     // 15 members, 2 weeks, best Sat afternoon 13 of 15
    case loading       // custom skeletons in every module
    case noFriends     // empty wheel, no proposal
    case fewFriends    // 3 members: faces evenly spaced, no arcs
    case noProposal    // members, but "No plans brewing"
    case zeroOverlap   // proposal with no slots: "No overlap yet. Nudge your crew."
    case singleWeek    // one week, page dots hidden
    case stale         // populated, last updated 6 min before launch
    // Issue #5: the recipient loop on the in-memory store.
    case lockedInvite          // 10 recipients, expected 10, best Sat afternoon 7 of 10; you (Cleo) are not free there
    case lockedInviteCreator   // the same crew as Sam, the creator, not free at the best cell
    case shortOverlap          // as Sam at quorum, but the best cell's overlap is only 80 minutes (lock sheet durations)
    case creatorAlone          // Sam alone on a new plan for 8: "Invite friends"
    case lockedPlan            // locked Sat Nov 14 12:00-14:00; you (Maya) are in
    case lockedWithoutYou      // locked; you (Cleo) weren't free then
    case lockedLateJoiner      // locked; you (Pia) joined after the lock
    case signedOut             // populated roster but no signed-in identity (gate test)
    case expiringHold          // one hold expired, one expiring in 2h (G18)
    case invites               // several plans for the Invites list order
    // Place voting (#10, #12). All use the ten-person crew and a pinned city of Austin, TX.
    case placesEmpty           // friend; requesting, city set, no places
    case placesVoting          // friend; four places from three suggesters, nine votes, the viewer voted for one
    case placesTied            // friend; two places tied 2 to 2, different creation times
    case placesVetoed          // host; three active places and one the host passed on
    case placesLockReady       // host; at quorum, city set, four places, exactly one leads
    case placesLocked          // friend; locked, lockedPlaceID set, places and votes frozen
    case placesLockedNoWinner  // friend; locked, places exist, none had a vote, lockedPlaceID nil
    case noCity                // friend; requesting, no city
    case noCityHost            // host; requesting, no city
    case placesZeroVotes       // friend; three places, none with a vote
    case placesOwnLeader       // friend; the viewer's own suggestion has the most votes
    case placesDeparted        // friend; locked; one suggester and one voter have deleted their accounts
    case placesCapped          // friend; the viewer has 2 active places, so Suggest is replaced by the cap line

    /// `-FriendCalFixture <name>` on the launch arguments (UI tests); populated otherwise.
    static var fromLaunchArguments: FixtureScenario {
        UserDefaults.standard.string(forKey: "FriendCalFixture").flatMap(FixtureScenario.init(rawValue:)) ?? .populated
    }
}

/// The app clock. `-FriendCalNow 2026-11-10T12:00` (local calendar) pins it for UI tests whose
/// outcome depends on today (past cells, Invites order); the wall clock otherwise.
enum FixtureClock {
    static let pinned: Date? = {
        guard let text = UserDefaults.standard.string(forKey: "FriendCalNow") else { return nil }
        let f = DateFormatter()
        f.calendar = .current
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: text)
    }()

    static func now() -> Date { pinned ?? Date() }
}

struct HomeFixture {
    var groupName: String
    var members: [HomeMember]
    var proposal: Proposal?
    var slots: [AvailabilitySlot]
    var lastUpdated: Date
    var isLoading = false
    /// Who is signed in; nil = the proposal's creator, else the first member.
    var currentUserID: UUID?
    /// Other plans the store lists on the Invites tab.
    var extraProposals: [Proposal] = []
    var busyBlocks: [BusyBlock] = []
    /// Place voting (#10): the places and votes of `proposal`.
    var places: [Place] = []
    var votes: [PlaceVote] = []
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

    static func member(_ name: String) -> HomeMember { members.first { $0.name == name }! }

    /// commonCount per cell, [week][daypart][day Mon...Sun]; nil = outside the window.
    /// Week 1 matches the approved mockup; the window opens Monday 17:00.
    static let grid: [[[Int?]]] = [
        [[nil, 3, 3, 7, 5, 6, 5], [nil, 9, 8, 9, 10, 13, 9], [3, 6, 8, 6, 4, 7, 3]],
        [[4, 2, 5, 6, 8, 11, 9], [6, 5, 7, 8, 9, 10, 7], [5, 7, 6, 9, 12, 8, 4]],
    ]

    /// The 3-member fixture's own counts (0-3), so it doesn't read as every cell 3/3.
    /// Bests: Sat afternoon (week 1), Thu evening (week 2).
    static let fewGrid: [[[Int?]]] = [
        [[nil, 1, 0, 2, 1, 2, 1], [nil, 2, 1, 2, 2, 3, 1], [1, 0, 2, 1, 0, 2, 1]],
        [[0, 1, 1, 2, 1, 2, 2], [1, 2, 1, 2, 1, 2, 1], [1, 1, 2, 3, 1, 1, 0]],
    ]

    /// The 10-member invite crew: best Sat afternoon (week 1) 7 of 10, one short of quorum (8).
    static let inviteGrid: [[[Int?]]] = [
        [[nil, 2, 3, 4, 3, 5, 4], [nil, 5, 4, 6, 5, 7, 6], [2, 4, 5, 4, 3, 5, 2]],
        [[3, 2, 4, 5, 6, 6, 5], [4, 3, 5, 6, 5, 6, 4], [3, 4, 5, 6, 5, 4, 3]],
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
        case .lockedInvite:
            return invite(group: group, you: member("Cleo"), now: now, calendar: calendar)
        case .lockedInviteCreator:
            return invite(group: group, you: member("Sam"), now: now, calendar: calendar)
        case .shortOverlap:
            var quorum = inviteGrid
            quorum[0][1][5] = 8
            return invite(group: group, you: member("Sam"), grid: quorum, bestCellMinutes: 80, now: now, calendar: calendar)
        case .creatorAlone:
            let sam = member("Sam")
            let mon = monday(calendar)
            let window = DateRange(lower: mon, upper: calendar.date(byAdding: .day, value: 14, to: mon)!.addingTimeInterval(-1))
            let p = Proposal(id: proposalID, title: "Brunch", window: window, createdBy: sam.id,
                             distribution: Distribution(mode: .newGroup, recipientIDs: [sam.id]), createdAt: mon, expectedCount: 8)
            return HomeFixture(groupName: group, members: [sam], proposal: p, slots: [], lastUpdated: now, currentUserID: sam.id)
        case .lockedPlan:
            return locked(group: group, you: member("Maya"), now: now, calendar: calendar)
        case .lockedWithoutYou:
            return locked(group: group, you: member("Cleo"), now: now, calendar: calendar)
        case .lockedLateJoiner:
            return locked(group: group, you: member("Pia"), lateJoiner: true, now: now, calendar: calendar)
        case .signedOut:
            var f = populated(group: group, members: members, weeks: 2, now: now, calendar: calendar)
            f.currentUserID = nil
            return f
        case .expiringHold:
            return expiringHold(group: group, now: now, calendar: calendar)
        case .invites:
            var f = invite(group: group, you: member("Sam"), now: now, calendar: calendar)
            f.extraProposals = invitesList(calendar: calendar)
            return f
        case .placesEmpty, .placesVoting, .placesTied, .placesVetoed, .placesLockReady, .placesLocked, .placesLockedNoWinner,
             .noCity, .noCityHost, .placesZeroVotes, .placesOwnLeader, .placesDeparted, .placesCapped:
            return placesScenario(scenario, group: group, now: now, calendar: calendar)
        }
    }

    static func fixtureID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    // MARK: Store

    /// Seeds the in-memory store from a fixture (issue #5 D2, D7). Users come from the members
    /// (any other recipient id reads "Friend"); the current user is the fixture's, else the creator,
    /// else the first member.
    @MainActor
    static func store(_ fixture: HomeFixture, clock: @escaping () -> Date) -> InMemoryProposalStore {
        let users = fixture.members.map { User(id: $0.id, displayName: $0.name) }
        let proposals = [fixture.proposal].compactMap { $0 } + fixture.extraProposals
        let current = fixture.currentUserID ?? fixture.proposal?.createdBy ?? fixture.members.first?.id
        return InMemoryProposalStore(users: users, proposals: proposals, slots: fixture.slots, busyBlocks: fixture.busyBlocks,
                                     places: fixture.places, votes: fixture.votes, currentUserID: current, now: clock)
    }

    private static func expiringHold(group: String, now: Date, calendar: Calendar) -> HomeFixture {
        var f = populated(group: group, members: members, weeks: 2, now: now, calendar: calendar)
        guard let proposal = f.proposal else { return f }
        let expired = AvailabilitySlot(id: fixtureID(8100), userID: members[0].id, range: DateRange(lower: now.addingTimeInterval(3600), upper: now.addingTimeInterval(7200)), sourceProposalID: proposal.id, state: .softHold, createdAt: now.addingTimeInterval(-3600), expiresAt: now.addingTimeInterval(-60))
        let expiring = AvailabilitySlot(id: fixtureID(8101), userID: members[0].id, range: DateRange(lower: now.addingTimeInterval(7200), upper: now.addingTimeInterval(10800)), sourceProposalID: proposal.id, state: .softHold, createdAt: now, expiresAt: now.addingTimeInterval(7200))
        f.slots = [expired, expiring] + f.slots
        f.currentUserID = members[0].id
        return f
    }

    // MARK: Places

    static let austin = SearchArea(name: "Austin, TX", latitude: 30.2672, longitude: -97.7431)

    /// Collects places and votes with stable ids and times, so two builds of one scenario compare equal.
    private struct PlaceBuilder {
        let proposalID: UUID
        let base: Date
        var places: [Place] = []
        var votes: [PlaceVote] = []

        @discardableResult
        mutating func add(_ name: String, by: HomeMember, address: String? = nil, lat: Double = 30.2672, lon: Double = -97.7431, vetoed: Bool = false) -> Place {
            let n = places.count + 1
            let at = base.addingTimeInterval(Double(n) * 60)
            let place = Place(id: FixtureData.fixtureID(7000 + n), proposalID: proposalID, suggestedBy: by.id, name: name, address: address,
                              latitude: lat, longitude: lon, mapRef: "fixture:\(name)", vetoedAt: vetoed ? at.addingTimeInterval(3600) : nil, createdAt: at)
            places.append(place)
            return place
        }

        mutating func vote(_ voter: HomeMember, for place: Place) {
            votes.append(PlaceVote(proposalID: proposalID, voterID: voter.id, placeID: place.id,
                                   createdAt: base.addingTimeInterval(Double(places.count) * 60 + Double(votes.count + 1))))
        }
    }

    private static func placesScenario(_ scenario: FixtureScenario, group: String, now: Date, calendar: Calendar) -> HomeFixture {
        let sam = member("Sam"), maya = member("Maya"), leo = member("Leo"), nina = member("Nina"), arlo = member("Arlo")
        let mika = member("Mika"), rosa = member("Rosa"), dev = member("Dev"), theo = member("Theo"), cleo = member("Cleo")
        var f: HomeFixture
        switch scenario {
        case .placesLocked, .placesLockedNoWinner, .placesDeparted:
            f = locked(group: group, you: maya, now: now, calendar: calendar)
        case .placesLockReady, .placesVetoed, .noCityHost:
            f = invite(group: group, you: sam, now: now, calendar: calendar)
        default:
            f = invite(group: group, you: cleo, now: now, calendar: calendar)
        }
        guard var plan = f.proposal else { return f }
        if scenario != .noCity && scenario != .noCityHost { plan.area = austin }
        var b = PlaceBuilder(proposalID: plan.id, base: plan.createdAt)

        switch scenario {
        case .placesVoting:
            let lola = b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            let juniper = b.add("Juniper Table", by: leo, address: "1100 S Lamar Blvd", lat: 30.2531, lon: -97.7650)
            let bluebonnet = b.add("Bluebonnet Diner", by: cleo, address: "1209 Barton Springs Rd", lat: 30.2640, lon: -97.7600)
            let taqueria = b.add("Eastside Taqueria", by: maya, address: "1501 E 7th St", lat: 30.2650, lon: -97.7270)
            for v in [sam, nina, arlo, rosa] { b.vote(v, for: lola) }
            for v in [maya, dev] { b.vote(v, for: juniper) }
            for v in [mika, theo] { b.vote(v, for: bluebonnet) }
            b.vote(cleo, for: taqueria)           // nine votes; the viewer's is for Eastside Taqueria
        case .placesTied:
            let lola = b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            let juniper = b.add("Juniper Table", by: leo, address: "1100 S Lamar Blvd", lat: 30.2531, lon: -97.7650)
            for v in [sam, nina] { b.vote(v, for: lola) }
            for v in [arlo, rosa] { b.vote(v, for: juniper) }
        case .placesVetoed:
            let lola = b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            let juniper = b.add("Juniper Table", by: leo, address: "1100 S Lamar Blvd", lat: 30.2531, lon: -97.7650)
            let bluebonnet = b.add("Bluebonnet Diner", by: nina, address: "1209 Barton Springs Rd", lat: 30.2640, lon: -97.7600)
            b.add("Hole in the Wall", by: dev, address: "2538 Guadalupe St", lat: 30.2960, lon: -97.7430, vetoed: true)
            for v in [arlo, rosa, mika] { b.vote(v, for: lola) }
            for v in [maya, theo] { b.vote(v, for: juniper) }
            b.vote(leo, for: bluebonnet)
        case .placesLockReady:
            let lola = b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            let juniper = b.add("Juniper Table", by: leo, address: "1100 S Lamar Blvd", lat: 30.2531, lon: -97.7650)
            let bluebonnet = b.add("Bluebonnet Diner", by: nina, address: "1209 Barton Springs Rd", lat: 30.2640, lon: -97.7600)
            b.add("Eastside Taqueria", by: dev, address: "1501 E 7th St", lat: 30.2650, lon: -97.7270)
            for v in [arlo, rosa, mika] { b.vote(v, for: lola) }      // exactly one place leads
            for v in [maya, theo] { b.vote(v, for: juniper) }
            b.vote(leo, for: bluebonnet)
        case .placesLocked:
            let lola = b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            let juniper = b.add("Juniper Table", by: leo, address: "1100 S Lamar Blvd", lat: 30.2531, lon: -97.7650)
            for v in [sam, nina, arlo, rosa] { b.vote(v, for: lola) }
            for v in [dev, mika] { b.vote(v, for: juniper) }
            plan.lockedPlaceID = lola.id
        case .placesLockedNoWinner:
            b.add("Cafe Lola", by: leo, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            b.add("Juniper Table", by: nina, address: "1100 S Lamar Blvd", lat: 30.2531, lon: -97.7650)
        case .placesZeroVotes:
            b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            b.add("Juniper Table", by: leo, address: "1100 S Lamar Blvd", lat: 30.2531, lon: -97.7650)
            b.add("Bluebonnet Diner", by: nina, address: "1209 Barton Springs Rd", lat: 30.2640, lon: -97.7600)
        case .placesOwnLeader:
            let lola = b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            let bluebonnet = b.add("Bluebonnet Diner", by: cleo, address: "1209 Barton Springs Rd", lat: 30.2640, lon: -97.7600)
            for v in [sam, nina, arlo] { b.vote(v, for: bluebonnet) }  // the viewer's own place leads: YOURS, no Vote pill
            b.vote(leo, for: lola)
        case .placesDeparted:
            // Locked; Leo suggested Juniper Table and Arlo voted for it, and both have deleted their accounts:
            // the tombstone's name is what the store hands back, and the session shows "A friend".
            let lola = b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            let juniper = b.add("Juniper Table", by: leo, address: "1100 S Lamar Blvd", lat: 30.2531, lon: -97.7650)
            for v in [sam, nina] { b.vote(v, for: lola) }
            for v in [arlo, theo] { b.vote(v, for: juniper) }
            plan.lockedPlaceID = lola.id
            f.members = f.members.map { m in
                guard m.id == leo.id || m.id == arlo.id else { return m }
                return HomeMember(id: m.id, name: User.deletedDisplayName, isOnline: m.isOnline, isActive: m.isActive)
            }
        case .placesCapped:
            b.add("Bluebonnet Diner", by: cleo, address: "1209 Barton Springs Rd", lat: 30.2640, lon: -97.7600)
            b.add("Eastside Taqueria", by: cleo, address: "1501 E 7th St", lat: 30.2650, lon: -97.7270)
            let lola = b.add("Cafe Lola", by: maya, address: "2108 E Cesar Chavez St", lat: 30.2569, lon: -97.7167)
            for v in [sam, nina] { b.vote(v, for: lola) }
        case .placesEmpty, .noCity, .noCityHost:
            break
        default:
            break
        }
        f.proposal = plan
        f.places = b.places
        f.votes = b.votes
        return f
    }

    // MARK: Builders

    static let proposalID = fixtureID(900)
    /// Sat Nov 14 2026, the locked plan's day.
    static func lockedWindow(_ calendar: Calendar) -> DateRange {
        let sat = calendar.date(byAdding: .day, value: 5, to: monday(calendar))!
        return DateRange(lower: calendar.date(bySettingHour: 12, minute: 0, second: 0, of: sat)!,
                         upper: calendar.date(bySettingHour: 14, minute: 0, second: 0, of: sat)!)
    }

    private static func monday(_ calendar: Calendar) -> Date { calendar.date(from: weekOne)! }

    private static func proposal(to members: [HomeMember], weeks: Int, calendar: Calendar, expectedCount: Int? = nil) -> Proposal {
        let mon = monday(calendar)
        let lower = calendar.date(bySettingHour: 17, minute: 0, second: 0, of: mon)!
        let upper = calendar.date(byAdding: .day, value: 7 * weeks, to: mon)!
        // Fixed createdAt: two fixtures built from the same scenario must compare equal.
        return Proposal(id: proposalID, title: "Brunch", window: DateRange(lower: lower, upper: upper),
                        createdBy: members.first?.id ?? fixtureID(0),
                        distribution: Distribution(mode: .newGroup, recipientIDs: members.map(\.id)),
                        createdAt: mon, expectedCount: expectedCount ?? members.count)
    }

    private static func populated(group: String, members: [HomeMember], weeks: Int, now: Date, calendar: Calendar) -> HomeFixture {
        let p = proposal(to: members, weeks: weeks, calendar: calendar)
        let counts = members.count <= 3 ? fewGrid : grid
        let order = { (week: Int, part: Daypart, day: Int) -> [HomeMember] in
            // The best cell (Sat afternoon, week 1) leaves out Maya (maybe) and Nina (busy) so the
            // first chips match the mockup; other cells rotate through the group.
            if week == 0, part == .afternoon, day == 5, members.count == 15 {
                let out = members.filter { $0.name != "Maya" && $0.name != "Nina" }
                return out + members.filter { $0.name == "Maya" } + members.filter { $0.name == "Nina" }
            }
            return rotated(members, week: week, part: part, dayIndex: day)
        }
        return HomeFixture(groupName: group, members: members, proposal: p,
                           slots: slots(for: p, grid: counts, weeks: weeks, calendar: calendar, order: order), lastUpdated: now)
    }

    /// The invite crew (10 recipients, expected 10): `you` have not replied yet, so you hold nothing
    /// anywhere, the best cell reads "1 more friend" and your tap there reaches quorum. The others
    /// rotate through the remaining cells.
    private static func invite(group: String, you: HomeMember, grid: [[[Int?]]] = inviteGrid, bestCellMinutes: Int? = nil, now: Date, calendar: Calendar) -> HomeFixture {
        let crew = Array(members.prefix(10))
        let p = proposal(to: crew, weeks: 2, calendar: calendar)
        let others = crew.filter { $0.id != you.id }
        let order = { (week: Int, part: Daypart, day: Int) -> [HomeMember] in
            // `you` last everywhere: counts never reach 9, so you get neither a full nor a short slot.
            rotated(others, week: week, part: part, dayIndex: day) + [you]
        }
        return HomeFixture(groupName: group, members: crew, proposal: p,
                           slots: slots(for: p, grid: grid, weeks: 2, calendar: calendar, bestCellMinutes: bestCellMinutes, order: order),
                           lastUpdated: now, currentUserID: you.id)
    }

    /// The same crew after Sam locked Sat Nov 14 12:00-14:00: 8 attendees (not Theo, not Cleo), holds
    /// cleared, one Busy block per attendee (what lock_proposal writes).
    private static func locked(group: String, you: HomeMember, lateJoiner: Bool = false, now: Date, calendar: Calendar) -> HomeFixture {
        var crew = Array(members.prefix(10))
        var p = proposal(to: crew, weeks: 2, calendar: calendar)
        let window = lockedWindow(calendar)
        let attendees = crew.filter { $0.name != "Theo" && $0.name != "Cleo" }.map(\.id)
        ProposalService.apply(window: window, to: &p, attendees: attendees, at: window.lowerBound.addingTimeInterval(-16 * 3600))
        if lateJoiner {
            crew.append(you)
            p.distribution.recipientIDs.append(you.id)
            p.postLockRecipientIDs = [you.id]
        }
        let busy = attendees.map { BusyBlock(userID: $0, range: window, visibility: .public, hiddenFrom: [], createdAt: p.lockedAt ?? now) }
        return HomeFixture(groupName: group, members: crew, proposal: p, slots: [], lastUpdated: now, currentUserID: you.id, busyBlocks: busy)
    }

    /// Other plans for the Invites list (design 1.7A order): a locked upcoming dinner (hosted by
    /// Maya), a requesting hike whose window already ended, and a locked movie night in the past.
    private static func invitesList(calendar: Calendar) -> [Proposal] {
        let mon = monday(calendar)
        func day(_ offset: Int, _ hour: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: offset, to: mon)!)!
        }
        let five = Array(members.prefix(5))
        var dinner = Proposal(id: fixtureID(901), title: "Dinner", window: DateRange(lower: day(-7), upper: day(7).addingTimeInterval(-1)),
                              createdBy: member("Maya").id, distribution: Distribution(mode: .newGroup, recipientIDs: five.map(\.id)), createdAt: day(-7), expectedCount: 5)
        ProposalService.apply(window: DateRange(lower: day(5, 18), upper: day(5, 20)), to: &dinner, attendees: five.map(\.id), at: day(-1, 20))
        let hike = Proposal(id: fixtureID(902), title: "Hike", window: DateRange(lower: day(-21), upper: day(-8).addingTimeInterval(-1)),
                            createdBy: member("Sam").id, distribution: Distribution(mode: .newGroup, recipientIDs: five.map(\.id)), createdAt: day(-21), expectedCount: 6)
        var movie = Proposal(id: fixtureID(903), title: "Movie night", window: DateRange(lower: day(-28), upper: day(-14).addingTimeInterval(-1)),
                             createdBy: member("Leo").id, distribution: Distribution(mode: .newGroup, recipientIDs: five.map(\.id)), createdAt: day(-28), expectedCount: 5)
        ProposalService.apply(window: DateRange(lower: day(-20, 19), upper: day(-20, 21)), to: &movie, attendees: five.map(\.id), at: day(-22))
        return [dinner, hike, movie]
    }

    /// Per cell with count n: n members get a slot covering the whole daypart (so commonCount = n);
    /// of the rest, one gets a 30-min slot at the start (maybe), one a 45-min slot two hours in
    /// (after N) when at least three are left, and the others nothing (busy). Both short slots are
    /// under 60 min, so they never change the common window.
    private static func slots(for proposal: Proposal, grid: [[[Int?]]], weeks: Int, calendar: Calendar, bestCellMinutes: Int? = nil, order: (Int, Daypart, Int) -> [HomeMember]) -> [AvailabilitySlot] {
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
                    let ordered = order(week, part, dayIndex)
                    let n = min(count, ordered.count)
                    // The best cell (Sat afternoon, week 1) can hold a shorter shared span.
                    let minutes = (week == 0 && part == .afternoon && dayIndex == 5) ? (bestCellMinutes ?? Int(end.timeIntervalSince(start) / 60)) : Int(end.timeIntervalSince(start) / 60)
                    for m in ordered.prefix(n) { add(m, start, minutes) }
                    let rest = Array(ordered.dropFirst(n))
                    if let maybe = rest.first { add(maybe, start, 30) }
                    if rest.count >= 3 { add(rest[1], start.addingTimeInterval(2 * 3600), 45) }
                }
            }
        }
        return out
    }

    /// Who is free where: cells rotate through the group.
    private static func rotated(_ members: [HomeMember], week: Int, part: Daypart, dayIndex: Int) -> [HomeMember] {
        guard !members.isEmpty else { return [] }
        let shift = (week * 21 + part.rawValue * 7 + dayIndex) * 4 % members.count
        return Array(members[shift...] + members[..<shift])
    }
}
