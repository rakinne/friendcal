import XCTest
@testable import FriendCalCore

/// The one number behind the invite (issue #5 S3, D13). Fixed New York calendar; 2026-11-09 is a Monday.
final class LockStateTests: XCTestCase {
    private let creator = UUID()
    private func mon(_ h: Int, _ m: Int = 0) -> Date { HeatmapTests.date(2026, 11, 9, h, m) }

    private func proposal(expected: Int, joined: Int, status: ProposalStatus = .requesting) -> Proposal {
        let ids = [creator] + (1..<max(joined, 1)).map { _ in UUID() }
        return Proposal(id: UUID(), title: "Brunch", window: DateRange(lower: mon(0), upper: HeatmapTests.date(2026, 11, 16, 0)),
                        createdBy: creator, distribution: Distribution(mode: .newGroup, recipientIDs: Array(ids.prefix(joined))),
                        status: status, expectedCount: expected)
    }

    /// One week whose Monday morning and Tuesday evening cells carry the given counts.
    private func weeks(total: Int, counts: [Int]) -> [HeatmapWeek] {
        let cells = counts.enumerated().map { i, n -> HeatmapCell in
            let day = HeatmapTests.date(2026, 11, 9 + i, 0)
            let interval = DateRange(lower: HeatmapTests.date(2026, 11, 9 + i, 6), upper: HeatmapTests.date(2026, 11, 9 + i, 12))
            return HeatmapCell(day: day, daypart: .morning, interval: interval, freeCount: n, commonCount: n, commonWindow: n > 0 ? interval : nil, total: total)
        }
        return [HeatmapWeek(weekStart: mon(0), cells: cells)]
    }

    /// protects=needed = ceil(0.8 x total) on both sides of the wire (ProposalService.quorumThreshold
    /// and lock_proposal's c_quorum); fails_when=rounding drifts (0.8 x 10 must be 8, not 9; 0.8 x 15
    /// must be 12); no_claim=the server constant (ProposalTests pins it).
    func testNeededTable() {
        let rows: [(Int, Int)] = [(1, 1), (2, 2), (3, 3), (4, 4), (5, 4), (8, 7), (10, 8), (12, 10), (15, 12), (20, 16)]
        for (total, needed) in rows {
            XCTAssertEqual(LockState.needed(total: total), needed, "total \(total)")
        }
    }

    /// protects=the caption number: have = the best cell's commonCount over every enabled cell, total =
    /// max(expected, joined), needed from the table above; fails_when=have sums counts or reads one
    /// week only, total ignores expected or joined, or the quorum boundary uses > instead of >=;
    /// no_claim=copy wording (the view) and the server's own recount.
    func testRequestingTable() {
        // (expected, joined, cell counts) -> (have, needed, total, quorum reached)
        let rows: [(Int, Int, [Int], Int, Int, Int, Bool)] = [
            (10, 10, [7, 3], 7, 8, 10, false),   // the lockedInvite fixture: "1 more friend"
            (10, 10, [8, 3], 8, 8, 10, true),    // have == needed: reached
            (8, 3, [3, 1], 3, 7, 8, false),      // expected > joined: the number is stable before everyone joins
            (2, 5, [4, 2], 4, 4, 5, true),       // joined > expected: everyone who joined counts
            (5, 5, [5, 5], 5, 4, 5, true),
            (10, 10, [0, 0], 0, 8, 10, false),   // nobody free yet
        ]
        for (expected, joined, counts, have, needed, total, reached) in rows {
            let p = proposal(expected: expected, joined: joined)
            let state = LockState.make(proposal: p, weeks: weeks(total: total, counts: counts))
            guard case .requesting(let h, let n, let t, let j, let best) = state else { return XCTFail("\(expected)/\(joined): \(state)") }
            XCTAssertEqual(h, have, "have \(expected)/\(joined)")
            XCTAssertEqual(n, needed, "needed \(expected)/\(joined)")
            XCTAssertEqual(t, total, "total \(expected)/\(joined)")
            XCTAssertEqual(j, joined, "joined \(expected)/\(joined)")
            XCTAssertEqual(state.isQuorumReached, reached, "reached \(expected)/\(joined)")
            XCTAssertEqual(state.remaining, max(0, needed - have), "remaining \(expected)/\(joined)")
            XCTAssertEqual(best?.commonCount, have > 0 ? have : nil, "best \(expected)/\(joined)")
        }
    }

    /// protects=have takes the max across weeks and ties go to the earliest cell; fails_when=a later
    /// week's bigger count is missed or a later equal count wins; no_claim=per-week best pills (HeatmapTests).
    func testBestCellSpansWeeksAndTiesEarliest() {
        let p = proposal(expected: 5, joined: 5)
        var two = weeks(total: 5, counts: [2, 2])
        two.append(HeatmapWeek(weekStart: HeatmapTests.date(2026, 11, 16, 0), cells: weeks(total: 5, counts: [4]).first!.cells))
        let state = LockState.make(proposal: p, weeks: two)
        XCTAssertEqual(state.bestCell?.commonCount, 4)
        let tie = LockState.make(proposal: p, weeks: weeks(total: 5, counts: [3, 3]))
        XCTAssertEqual(tie.bestCell?.day, mon(0))
    }

    /// protects=a creator alone reads as "Invite friends", never "Locked until 1 more friend";
    /// fails_when=ceil(0.8 x 1) produces a requesting state for one recipient; no_claim=copy.
    func testCreatorAloneIsInviteFriends() {
        XCTAssertEqual(LockState.make(proposal: proposal(expected: 8, joined: 1), weeks: weeks(total: 8, counts: [1])), .inviteFriends(expected: 8))
        XCTAssertEqual(LockState.make(proposal: proposal(expected: 1, joined: 1), weeks: []), .inviteFriends(expected: 1))
        XCTAssertFalse(LockState.inviteFriends(expected: 8).isQuorumReached)
    }

    /// protects=a locked plan reads its window and attendees from the proposal row (C1, X1) and
    /// separates pre-lock non-attendees from post-lock joiners (delta O1); fails_when=the locked branch
    /// reads holds or busy blocks, or joinedAfterLock is dropped; no_claim=lock_proposal writes the columns.
    func testLockedReadsTheProposalRow() {
        var p = proposal(expected: 10, joined: 10, status: .locked)
        let window = DateRange(lower: mon(10), upper: mon(12))
        let attendees = Array(p.distribution.recipientIDs.prefix(8))
        let late = UUID()
        p.lockedDate = window.lowerBound
        p.lockedEnd = window.upperBound
        p.lockedAttendeeIDs = attendees
        p.distribution.recipientIDs.append(late)
        p.postLockRecipientIDs = [late]
        let state = LockState.make(proposal: p, weeks: weeks(total: 11, counts: [0]))
        XCTAssertEqual(state, .locked(window: window, attendees: attendees, joinedAfterLock: [late]))
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.isQuorumReached)
        XCTAssertEqual(state.remaining, 0)
    }
}
