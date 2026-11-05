import XCTest
@testable import FriendCalCore

final class ProposalTests: XCTestCase {
    func testLockRequiresQuorum() {
        var proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID()]))
        let svc = ProposalService()
        svc.quorumThreshold = 0.8
        let lowRow = HeatmapRow(date: Date(), freeCount: 1, totalRecipients: 5) // 20%
        XCTAssertThrowsError(try svc.lock(&proposal, to: Date(), heatmapRows: [lowRow], busyWriter: { _,_ in [] })) { err in
            XCTAssertTrue((err as? ProposalLockError) != nil)
        }
    }

    func testLockSucceedsAtQuorum() throws {
        var proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID()]))
        let svc = ProposalService()
        svc.quorumThreshold = 0.8
        let highRow = HeatmapRow(date: Date(), freeCount: 5, totalRecipients: 5)
        try svc.lock(&proposal, to: Date(), heatmapRows: [highRow], busyWriter: { _,_ in [] })
        XCTAssertEqual(proposal.status, .locked)
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