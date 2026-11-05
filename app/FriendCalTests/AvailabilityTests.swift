import XCTest
@testable import FriendCalCore

final class AvailabilityTests: XCTestCase {
    func testTapFreeCreatesSoftHold() {
        let svc = AvailabilityService()
        let res = svc.tapFreeSlot(userID: UUID(), range: Date.now...Date.now.addingTimeInterval(7200), proposalID: UUID(), expiresAt: Date().addingTimeInterval(86400))
        if case .softHold(let slot) = res {
            XCTAssertEqual(slot.state, .softHold)
        } else { XCTFail("expected softHold") }
    }

    func testSoftHoldExpires() {
        let svc = AvailabilityService()
        let expired = AvailabilitySlot(userID: UUID(), range: Date.now...Date.now, sourceProposalID: nil, state: .softHold, expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(expired.isExpired)
        XCTAssertEqual(svc.expireStaleHolds(slots: [expired]).count, 0)
    }
}
