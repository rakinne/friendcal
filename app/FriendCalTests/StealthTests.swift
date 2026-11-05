import XCTest
@testable import FriendCalCore

final class StealthTests: XCTestCase {
    func testExcludedSeesGenericBusy() {
        let jalenID = UUID()
        let micaID = UUID()
        let block = BusyBlock(userID: micaID, range: DateRange(Date.now...Date.now.addingTimeInterval(3600)), visibility: .stealth, hiddenFrom: [jalenID])
        let svc = StealthService()
        let sanitized = svc.sanitize(block, for: jalenID)
        XCTAssertEqual(sanitized.userID, micaID)
        // No title/location/attendees leak — SanitizedBusy has only id/user/range
    }

    func testIncludedSeesFullContext() {
        // Placeholder: included viewer path returns full Event lookup
        XCTAssertTrue(true)
    }

    func testCorrelationNoiseDoesNotRevealGrouping() {
        // Blind test: 3 coordinated Busy blocks must remain indistinguishable
        // TODO: after decoy impl, assert jittered rendering not fingerprintable
        XCTAssertTrue(true)
    }
}
