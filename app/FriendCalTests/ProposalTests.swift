import XCTest
@testable import FriendCalCore

final class ProposalTests: XCTestCase {
    func testLockRequiresQuorum() {
        var proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID()]))
        let svc = ProposalService()
        svc.quorumThreshold = 0.8
        let lowCell = Self.cell(commonCount: 1, total: 5) // 20%
        XCTAssertThrowsError(try svc.lock(&proposal, to: lowCell, busyWriter: { _,_ in [] })) { err in
            XCTAssertTrue((err as? ProposalLockError) != nil)
        }
    }

    func testLockSucceedsAtQuorum() throws {
        var proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID()]))
        let svc = ProposalService()
        svc.quorumThreshold = 0.8
        let highCell = Self.cell(commonCount: 5, total: 5)
        try svc.lock(&proposal, to: highCell, busyWriter: { _,_ in [] })
        XCTAssertEqual(proposal.status, .locked)
    }

    private static func cell(commonCount: Int, total: Int) -> HeatmapCell {
        let start = Date()
        let interval = DateRange(lower: start, upper: start.addingTimeInterval(5 * 3600))
        return HeatmapCell(day: start, daypart: .afternoon, interval: interval, freeCount: commonCount, commonCount: commonCount, commonWindow: commonCount > 0 ? interval : nil, total: total)
    }

    func testPokeRateLimit() async {
        let svc = PokeService()
        let from = UUID(), to = UUID(), pid = UUID()
        let first = await svc.recordPokeSafe(from: from, to: to, proposalID: pid)
        XCTAssertNotNil(first)
        let second = await svc.recordPokeSafe(from: from, to: to, proposalID: pid)
        XCTAssertNil(second, "second poke within 24h must be nil")
    }

    func testDesignTokensHexParsing() {
        XCTAssertEqual(Proposal(id: UUID(), title: "t", window: DateRange(Date.now...Date.now.addingTimeInterval(100)), createdBy: UUID(), distribution: Distribution(mode: .separately, recipientIDs: [])).title, "t")
    }
}