import Foundation
import FriendCalCore

/// Which Groups state the app opens in. `-FriendCalGroups crew|friends|alone` pins it for UI tests
/// and previews; otherwise a fixture with members opens as `crew` and one with none as `alone`.
enum GroupsScenario: String {
    case crew      // you + 5 in "Friendsgivemas Crew", 2 in "Brunch Club": the approved variant D
    case friends   // five friends, no crew yet: the automatic folder and "Start a crew"
    case alone     // no friends: your row and an invite card

    static var fromLaunchArguments: GroupsScenario? {
        UserDefaults.standard.string(forKey: "FriendCalGroups").flatMap(GroupsScenario.init(rawValue:))
    }
}

extension GroupsSession.Seed {
    /// Builds a seed from the Home fixture's roster. `youID` is the signed-in user; with none in the
    /// roster, "You" is added. Statuses are relative to `now`, so the screen reads the same at any
    /// hour: Maya at work till late, Leo mid-movie, Nina at a show, Arlo free, Mika plain busy.
    static func make(fixture: HomeFixture, youID: UUID?, scenario: GroupsScenario? = nil, now: Date) -> Self {
        let roster = fixture.members
        let me = roster.first { $0.id == youID }.map { Buddy(id: $0.id, name: $0.name) }
            ?? Buddy(id: youID ?? FixtureData.fixtureID(9_000), name: "You")
        let mode = scenario ?? (roster.isEmpty ? .alone : .crew)
        if mode == .alone { return Self(you: me, friends: [], crews: []) }

        func friend(_ name: String) -> Buddy? {
            roster.first { $0.name == name && $0.id != me.id }.map { Buddy(id: $0.id, name: $0.name, isOnline: $0.isOnline) }
        }
        let cast = ["Maya", "Leo", "Nina", "Arlo", "Mika"].compactMap(friend)
        let extras = ["Rosa", "Dev"].compactMap(friend)
        let friends = cast + (mode == .crew ? extras : [])

        var seed = Self(you: me, friends: friends, crews: [])
        func minutes(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }
        func set(_ buddy: Buddy?, _ status: FriendStatus) { if let buddy { seed.statuses[buddy.id] = status } }
        set(friend("Maya"), FriendStatus(kind: .work, message: "closing shift, send snacks", since: minutes(-5), until: minutes(170)))
        set(friend("Leo"), FriendStatus(kind: .movies, message: "dune part three, no spoilers", since: minutes(-35), until: minutes(90)))
        set(friend("Nina"), FriendStatus(kind: .concert, message: "khruangbin row 4", since: minutes(-40)))
        set(friend("Arlo"), FriendStatus(kind: .free, message: "down for tacos, anyone", since: minutes(-10)))
        if let mika = friend("Mika") {
            seed.busyNow.insert(mika.id)
            seed.busyBlocks[mika.id] = [DateInterval(start: minutes(-30), end: minutes(150))]
        }
        if let maya = friend("Maya") { seed.busyBlocks[maya.id] = [DateInterval(start: minutes(-480), end: minutes(-300))] }

        if mode == .crew {
            seed.crews = [Crew(name: "Friendsgivemas Crew", memberIDs: cast.map(\.id))]
            if !extras.isEmpty { seed.crews.append(Crew(name: "Brunch Club", memberIDs: extras.map(\.id))) }
        }
        return seed
    }
}
