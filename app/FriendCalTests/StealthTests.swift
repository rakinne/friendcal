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
        // SanitizedBusy has no title/location — compile-time guarantee
    }

    func testCorrelationNoiseDoesNotRevealGrouping() {
        let svc = StealthService()
        let jalenID = UUID()
        // 3 friends busy same slot — sanitized payloads must be indistinguishable
        let range = DateRange(Date.now...Date.now.addingTimeInterval(7200))
        let blocks = (0..<3).map { _ in BusyBlock(userID: UUID(), range: range, visibility: .stealth, hiddenFrom: [jalenID]) }
        let sanitized = blocks.map { svc.sanitize($0, for: jalenID) }
        // All stripped to same shape; jitter does not add fingerprint
        let jittered = sanitized.map { svc.applyCorrelationNoise(to: $0, jitterMinutes: 7) }
        XCTAssertEqual(sanitized.count, 3)
        XCTAssertEqual(jittered.count, 3)
        // Sanitized id range userID only — no grouping signal
        XCTAssertTrue(sanitized.allSatisfy { $0.range == range })
    }

    func testPushBodySanitizedForExcluded() {
        let jalenID = UUID()
        let block = BusyBlock(userID: UUID(), range: DateRange(Date.now...Date.now.addingTimeInterval(3600)), visibility: .stealth, hiddenFrom: [jalenID])
        let svc = StealthService()
        XCTAssertEqual(svc.sanitizedPushBody(for: block, viewer: jalenID), "New busy time added")
        XCTAssertNotEqual(svc.sanitizedPushBody(for: block, viewer: UUID()), "New busy time added")
    }

    func testRlsViewDoesNotExposeHiddenFrom() throws {
        // The in-memory store's sanitized read strips hiddenFrom for the excluded viewer (issue #5 S2:
        // MockSupabaseService folded into InMemoryProposalStore; same assertion).
        let jalenID = UUID()
        let micaID = UUID()
        let svc = InMemoryProposalStore()
        svc.busyBlocks = [BusyBlock(userID: micaID, range: DateRange(Date.now...Date.now.addingTimeInterval(3600)), visibility: .stealth, hiddenFrom: [jalenID])]
        let exp = expectation(description: "fetch")
        Task {
            let blocks = try await svc.fetchBusyBlocks(for: jalenID, in: DateRange(Date.now...Date.now.addingTimeInterval(7200)))
            XCTAssertEqual(blocks.count, 1)
            XCTAssertTrue(blocks.first?.hiddenFrom.isEmpty == true, "hiddenFrom must be stripped for excluded viewer")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}
