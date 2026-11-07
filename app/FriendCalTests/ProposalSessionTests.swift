// HomeModel lives in the app target; SPM builds this folder against FriendCalCore only, so the
// test runs app-hosted under Xcode.
#if canImport(FriendCal)
import XCTest
@testable import FriendCal
@testable import FriendCalCore

final class HomeModelTests: XCTestCase {
    private let alice = HomeMember(id: UUID(), name: "Alice", isOnline: true, isActive: true)
    private let bob = HomeMember(id: UUID(), name: "Bob", isOnline: true, isActive: false)
    private func mon(_ h: Int, _ m: Int = 0) -> Date { HeatmapTests.date(2026, 11, 9, h, m) }

    /// protects=a hold that expires while Home stays open stops counting at the next refresh, with
    /// no new data (X12), and the selection follows X10; fails_when=refresh(now:) reuses the
    /// launch-time `now`, keeps the expired friend free, mutates the slots, or drops/moves the
    /// selection when the cell falls to 0; no_claim=the 60s timer and scenePhase wiring in
    /// HomeView fire (not driven here); fixture members and slots stand in for Supabase rows.
    func testRefreshPastExpiryDropsFriendWithoutSlotChange() throws {
        let proposal = Proposal(id: UUID(), title: "Brunch", window: DateRange(lower: mon(0), upper: HeatmapTests.date(2026, 11, 16, 0)),
                                createdBy: alice.id, distribution: Distribution(mode: .newGroup, recipientIDs: [alice.id, bob.id]))
        func hold(_ m: HomeMember, expires: Date) -> AvailabilitySlot {
            AvailabilitySlot(userID: m.id, range: DateRange(lower: mon(9), upper: mon(11)), sourceProposalID: proposal.id, state: .softHold, expiresAt: expires)
        }
        let slots = [hold(alice, expires: mon(8, 30)), hold(bob, expires: mon(8))]
        let fixture = HomeFixture(groupName: "Brunch crew", members: [alice, bob], proposal: proposal, slots: slots, lastUpdated: mon(7))
        let model = HomeModel(fixture: fixture, now: mon(7, 59), calendar: HeatmapTests.calendar)

        let cellID = HeatmapCell.ID(day: mon(0), daypart: .morning)
        XCTAssertEqual(model.selectedCellID, cellID)
        XCTAssertEqual(model.selectedCell?.commonCount, 2)

        model.refresh(now: mon(8, 1)) // Bob's hold expired at 08:00
        XCTAssertEqual(model.slots, slots)
        XCTAssertEqual(model.selectedCellID, cellID)
        XCTAssertEqual(model.selectedCell?.commonCount, 1)
        XCTAssertEqual(model.selectedCell?.roster, [alice.id: .free, bob.id: .busy])
        XCTAssertNotNil(model.shareText)

        model.refresh(now: mon(8, 31)) // Alice's too: the cell drops to 0 and stays selected
        XCTAssertEqual(model.selectedCellID, cellID)
        XCTAssertEqual(model.selectedCell?.commonCount, 0)
        XCTAssertNil(model.visibleWeek?.best)
        XCTAssertNil(model.shareText)
        XCTAssertEqual(model.shareDisabledHint, "Nobody shares an hour here yet")
        XCTAssertEqual(model.lastUpdated, mon(7))
    }
    /// Value: protects=past 10 members the wheel shows 9 faces incl. the active friend plus +N (D36);
    /// fails_when=the active swap, the 10-member cutoff or the overflow count changes;
    /// why_new=UI tests check the drawer, not which faces show; seam=none;
    /// no_claim=face layout on the orbit (FriendsWheel, UI lane only).
    func testWheelKeepsActiveFriendPastNine() {
        func members(_ n: Int, activeAt: Int) -> [HomeMember] {
            (0..<n).map { HomeMember(id: UUID(), name: "M\($0)", isOnline: false, isActive: $0 == activeAt) }
        }
        func model(_ ms: [HomeMember]) -> HomeModel {
            HomeModel(fixture: HomeFixture(groupName: "G", members: ms, proposal: nil, slots: [], lastUpdated: mon(7)), now: mon(8), calendar: HeatmapTests.calendar)
        }
        let ten = members(10, activeAt: 9)
        XCTAssertEqual(model(ten).wheel.faces, ten)
        XCTAssertEqual(model(ten).wheel.overflow, 0)

        let twelve = members(12, activeAt: 11)
        let w = model(twelve).wheel
        XCTAssertEqual(w.overflow, 3)
        XCTAssertEqual(w.faces.count, 9)
        XCTAssertEqual(Array(w.faces.prefix(8)), Array(twelve.prefix(8)))
        XCTAssertEqual(w.faces[8], twelve[11])

        let early = members(12, activeAt: 2)
        XCTAssertEqual(model(early).wheel.faces, Array(early.prefix(9)))
    }

    /// Value: protects=no proposal clears weeks/selection and Share says "Pick a time first"; only
    /// enabled cells of the visible week select; unknown weeks are ignored; fails_when=a guard in
    /// refresh/select/showWeek is dropped; why_new=existing test covers expiry only; seam=none;
    /// no_claim=tap and swipe gestures (UI lane).
    func testNoProposalAndSelectionGuards() {
        let empty = HomeModel(fixture: HomeFixture(groupName: "G", members: [alice], proposal: nil, slots: [], lastUpdated: mon(7)), now: mon(8), calendar: HeatmapTests.calendar)
        XCTAssertTrue(empty.weeks.isEmpty)
        XCTAssertNil(empty.selectedCellID)
        XCTAssertNil(empty.chips)
        XCTAssertEqual(empty.shareDisabledHint, "Pick a time first")

        // Window opens Monday 14:30 and spans two weeks; Monday morning is disabled.
        let proposal = Proposal(id: UUID(), title: "Brunch", window: DateRange(lower: mon(14, 30), upper: HeatmapTests.date(2026, 11, 23, 0)),
                                createdBy: alice.id, distribution: Distribution(mode: .newGroup, recipientIDs: [alice.id]))
        let model = HomeModel(fixture: HomeFixture(groupName: "G", members: [alice], proposal: proposal, slots: [], lastUpdated: mon(7)), now: mon(8), calendar: HeatmapTests.calendar)
        XCTAssertEqual(model.weeks.count, 2)
        XCTAssertNil(model.selectedCellID)
        model.select(HeatmapCell.ID(day: mon(0), daypart: .morning))
        XCTAssertNil(model.selectedCellID)
        let tueMorning = HeatmapCell.ID(day: HeatmapTests.date(2026, 11, 10, 0), daypart: .morning)
        model.select(tueMorning)
        XCTAssertEqual(model.selectedCellID, tueMorning)
        XCTAssertEqual(model.chips?.map(\.status), [.busy])
        model.select(HeatmapCell.ID(day: HeatmapTests.date(2026, 11, 17, 0), daypart: .morning)) // other week: ignored
        XCTAssertEqual(model.selectedCellID, tueMorning)
        model.showWeek(HeatmapTests.date(2026, 12, 1, 0)) // unknown week: ignored
        XCTAssertEqual(model.visibleWeekID, model.weeks[0].id)
        model.showWeek(model.weeks[1].id)
        XCTAssertEqual(model.visibleWeekID, model.weeks[1].id)
        XCTAssertNil(model.selectedCellID)
    }
}
#endif
