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
}
#endif
