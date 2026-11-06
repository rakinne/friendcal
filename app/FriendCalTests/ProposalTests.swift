import XCTest
@testable import FriendCalCore

final class ProposalTests: XCTestCase {
    func testLockRequiresQuorum() {
        var proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID()]))
        let svc = ProposalService()
        svc.quorumThreshold = 0.8
        let lowCell = Self.cell(commonCount: 1, total: 5) // 20%
        XCTAssertThrowsError(try svc.lock(&proposal, to: lowCell.id, in: Self.weeks(lowCell), busyWriter: { _,_ in [] })) { err in
            XCTAssertTrue((err as? ProposalLockError) != nil)
        }
    }

    func testLockSucceedsAtQuorum() throws {
        var proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID()]))
        let svc = ProposalService()
        svc.quorumThreshold = 0.8
        let highCell = Self.cell(commonCount: 5, total: 5)
        try svc.lock(&proposal, to: highCell.id, in: Self.weeks(highCell), busyWriter: { _,_ in [] })
        XCTAssertEqual(proposal.status, .locked)
    }

    func testLockWithNoRecipientsThrowsInsufficientRecipients() {
        var proposal = Self.proposal()
        let cell = Self.cell(commonCount: 0, total: 0)
        XCTAssertThrowsError(try ProposalService().lock(&proposal, to: cell.id, in: Self.weeks(cell), busyWriter: { _,_ in [] })) { err in
            guard case .insufficientRecipients = err as? ProposalLockError else { return XCTFail("got \(err)") }
        }
        XCTAssertEqual(proposal.status, .requesting)
    }

    func testLockToCellOutsideWindowThrowsCellNotInWindow() {
        let enabled = Self.cell(commonCount: 5, total: 5)
        let disabled = HeatmapCell(day: enabled.day, daypart: .morning, interval: nil, freeCount: 0, commonCount: 0, commonWindow: nil, total: 5)
        let missing = HeatmapCell(day: enabled.day.addingTimeInterval(-7 * 86400), daypart: .evening, interval: nil, freeCount: 0, commonCount: 0, commonWindow: nil, total: 5)
        for target in [disabled.id, missing.id] {
            var proposal = Self.proposal()
            XCTAssertThrowsError(try ProposalService().lock(&proposal, to: target, in: Self.weeks(enabled, disabled), busyWriter: { _,_ in [] })) { err in
                guard case .cellNotInWindow = err as? ProposalLockError else { return XCTFail("got \(err)") }
                XCTAssertNotNil((err as? LocalizedError)?.errorDescription)
            }
            XCTAssertNil(proposal.lockedDate)
        }
    }

    private static func proposal() -> Proposal {
        Proposal(id: UUID(), title: "Brunch", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID()]))
    }

    private static func weeks(_ cells: HeatmapCell...) -> [HeatmapWeek] {
        [HeatmapWeek(weekStart: cells[0].day, cells: cells)]
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