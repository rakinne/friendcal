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
        let (promoted, expired) = svc.promoteToBusy(onLock: day1, proposalID: proposalID, recipientIDs: [], slots: [s1, s2])
        XCTAssertEqual(promoted.count, 1)
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first, s2.id)
    }
}
