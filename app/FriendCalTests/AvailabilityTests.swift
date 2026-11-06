import XCTest
@testable import FriendCalCore

final class AvailabilityTests: XCTestCase {
    func testTapFreeCreatesSoftHold() {
        let svc = AvailabilityService()
        let res = svc.tapFreeSlot(userID: UUID(), range: DateRange(Date.now...Date.now.addingTimeInterval(7200)), proposalID: UUID(), expiresAt: Date().addingTimeInterval(86400))
        if case .softHold(let slot) = res {
            XCTAssertEqual(slot.state, .softHold)
        } else { XCTFail("expected softHold") }
    }

    func testSoftHoldExpires() {
        let svc = AvailabilityService()
        let expired = AvailabilitySlot(userID: UUID(), range: DateRange(Date.now...Date.now), sourceProposalID: nil, state: .softHold, expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(expired.isExpired)
        XCTAssertEqual(svc.expireStaleHolds(slots: [expired]).count, 0)
    }

    func testOverBlockCollisionBusyBlocksSecondTap() {
        let svc = AvailabilityService()
        let user = UUID()
        let busy = AvailabilitySlot(userID: user, range: DateRange(Date.now...Date.now.addingTimeInterval(7200)), sourceProposalID: nil, state: .busy)
        let res = svc.tapFreeSlot(userID: user, range: DateRange(Date.now...Date.now.addingTimeInterval(3600)), proposalID: UUID(), expiresAt: nil, existingSlots: [busy])
        if case .alreadyHeld = res { } else { XCTFail("busy should block softHold") }
    }

    func testPromoteOnLockMovesWinnerAndExpiresLosers() {
        let svc = AvailabilityService()
        let proposalID = UUID()
        let day1 = Date.now
        let day2 = Calendar.current.date(byAdding: .day, value: 1, to: Date.now)!
        let s1 = AvailabilitySlot(userID: UUID(), range: DateRange(lower: day1, upper: day1.addingTimeInterval(7200)), sourceProposalID: proposalID, state: .softHold, expiresAt: Date().addingTimeInterval(86400))
        let s2 = AvailabilitySlot(userID: UUID(), range: DateRange(lower: day2, upper: day2.addingTimeInterval(7200)), sourceProposalID: proposalID, state: .softHold, expiresAt: Date().addingTimeInterval(86400))
        let lockedWindow = DateRange(lower: day1, upper: day1.addingTimeInterval(3600))
        let (promoted, expired) = svc.promoteToBusy(window: lockedWindow, proposalID: proposalID, recipientIDs: [s1.userID, s2.userID], slots: [s1, s2])
        XCTAssertEqual(promoted.count, 1)
        XCTAssertEqual(promoted.first?.userID, s1.userID)
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first, s2.id)
    }

    /// D3 + D12: an Evening lock on a shared 18:00-19:30 window promotes the 18:00-20:00 hold, and
    /// expires a hold that only partly covers the window, another day's hold, and a non-recipient's.
    func testEveningLockPromotesSlotsCoveringCommonWindow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }
        let svc = AvailabilityService()
        let proposalID = UUID()
        let friend = UUID(), late = UUID(), other = UUID(), stranger = UUID()
        let expires = Date().addingTimeInterval(86400)
        func hold(_ user: UUID, _ from: Date, _ to: Date) -> AvailabilitySlot {
            AvailabilitySlot(userID: user, range: DateRange(lower: from, upper: to), sourceProposalID: proposalID, state: .softHold, expiresAt: expires)
        }
        let winner = hold(friend, at(14, 18), at(14, 20))
        let partial = hold(late, at(14, 19), at(14, 21))
        let otherDay = hold(other, at(15, 18), at(15, 20))
        let notInvited = hold(stranger, at(14, 18), at(14, 20))
        let window = DateRange(lower: at(14, 18), upper: at(14, 19, 30))
        let (promoted, expired) = svc.promoteToBusy(window: window, proposalID: proposalID, recipientIDs: [friend, late, other], slots: [winner, partial, otherDay, notInvited])
        XCTAssertEqual(promoted.map(\.userID), [friend])
        XCTAssertEqual(promoted.first?.range, winner.range)
        XCTAssertEqual(Set(expired), [partial.id, otherDay.id, notInvited.id])
    }
}
