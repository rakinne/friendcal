import XCTest
@testable import FriendCalCore

/// The commitment list's rules: what counts as live, what order it comes in, and how it groups.
///
/// The horizon tests are the load-bearing ones. "Am I committed from here on?" has a wrong answer
/// that is invisible except near midnight, which is precisely when someone checks.
final class CommitmentTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    private func commitment(
        _ kind: CommitmentKind,
        _ from: String,
        _ to: String,
        title: String? = nil,
        plan: UUID? = nil,
        expires: String? = nil,
        id: UUID = UUID()
    ) -> Commitment {
        Commitment(
            id: id,
            kind: kind,
            range: DateRange(lower: at(from), upper: at(to)),
            sourceProposalID: plan,
            planTitle: title,
            expiresAt: expires.map(at)
        )
    }

    // MARK: - The horizon

    /// protects=an overnight commitment that began before the horizon and is still running is
    /// treated as live; fails_when=inclusion becomes start-based (`lowerBound >= horizon`);
    /// no_claim=anything about ordering or grouping.
    func testOvernightCommitmentStillRunningIsLive() {
        let overnight = commitment(.busy, "2026-11-19T22:00:00Z", "2026-11-20T06:00:00Z")
        // Asked at 00:30, in the middle of it.
        XCTAssertTrue(overnight.isLive(at: at("2026-11-20T00:30:00Z")))
        // And at the start of the day it ends in.
        XCTAssertTrue(overnight.isLive(at: at("2026-11-20T00:00:00Z")))
        // A start-based filter would have excluded it at both; prove the start really is earlier.
        XCTAssertLessThan(overnight.range.lowerBound, at("2026-11-20T00:00:00Z"))
    }

    /// protects=the far boundary is half-open, matching the `[)` tstzrange the server stores;
    /// fails_when=`>=` creeps in and a finished commitment lingers for an instant; no_claim=the near
    /// boundary, which has no meaning for an overlap test.
    func testCommitmentEndingExactlyAtTheHorizonIsOver() {
        let c = commitment(.locked, "2026-11-19T22:00:00Z", "2026-11-20T06:00:00Z")
        XCTAssertFalse(c.isLive(at: at("2026-11-20T06:00:00Z")))
        XCTAssertTrue(c.isLive(at: at("2026-11-20T05:59:59Z")))
    }

    /// protects=a hold that lapsed is dropped even though its time is still in the future, which the
    /// horizon filter alone would keep; fails_when=`live` filters on only one of the two conditions;
    /// no_claim=non-held kinds, which carry no expiry.
    func testExpiredHoldInTheFutureIsDropped() {
        let now = at("2026-11-20T12:00:00Z")
        let lapsed = commitment(.held, "2026-11-24T18:00:00Z", "2026-11-24T20:00:00Z",
                                expires: "2026-11-20T09:00:00Z")
        let live = commitment(.held, "2026-11-24T18:00:00Z", "2026-11-24T20:00:00Z",
                              expires: "2026-11-30T09:00:00Z")
        XCTAssertTrue(lapsed.isLive(at: now), "its time is in the future, so the horizon keeps it")
        XCTAssertTrue(lapsed.isExpired(at: now), "but the hold itself is gone")

        let kept = Commitment.live([lapsed, live], from: now, now: now)
        XCTAssertEqual(kept.map(\.id), [live.id])
    }

    /// protects=the expiry boundary matches AvailabilitySlot exactly, so a hold does not appear in
    /// one place and not the other; fails_when=one side uses `>` and the other `>=`; no_claim=the
    /// nil case, covered below.
    func testExpiryBoundaryMatchesAvailabilitySlot() {
        let moment = at("2026-11-20T12:00:00Z")
        let c = commitment(.held, "2026-11-24T18:00:00Z", "2026-11-24T20:00:00Z",
                           expires: "2026-11-20T12:00:00Z")
        let slot = AvailabilitySlot(userID: UUID(),
                                   range: DateRange(lower: at("2026-11-24T18:00:00Z"), upper: at("2026-11-24T20:00:00Z")),
                                   sourceProposalID: nil, state: .softHold,
                                   expiresAt: at("2026-11-20T12:00:00Z"))
        XCTAssertEqual(c.isExpired(at: moment), slot.isExpired(at: moment))
        XCTAssertTrue(c.isExpired(at: moment), "expiresAt == now is already gone")
    }

    /// protects=a hold with no expiry never lapses, which is the hold that would otherwise block
    /// someone forever; fails_when=nil is treated as "expired now"; no_claim=whether such a hold
    /// should exist, which is a server concern.
    func testHoldWithoutExpiryNeverLapses() {
        let c = commitment(.held, "2026-11-24T18:00:00Z", "2026-11-24T20:00:00Z", expires: nil)
        XCTAssertFalse(c.isExpired(at: at("2030-01-01T00:00:00Z")))
    }

    // MARK: - Order

    /// protects=the four-key sort is total and stable, so the list cannot reorder between launches;
    /// fails_when=any key is dropped -- the kind key swaps a settled row with a tentative one, and
    /// the id key leaves identical rows unstable; no_claim=that the chosen kind ranking is the only
    /// defensible one, only that it is fixed.
    func testFourKeySortIsTotalAndStable() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let sameTimeHeld = commitment(.held, "2026-11-20T18:00:00Z", "2026-11-20T20:00:00Z", id: a)
        let sameTimeLocked = commitment(.locked, "2026-11-20T18:00:00Z", "2026-11-20T20:00:00Z", id: b)
        let earlier = commitment(.busy, "2026-11-20T09:00:00Z", "2026-11-20T10:00:00Z")
        let shorter = commitment(.busy, "2026-11-20T18:00:00Z", "2026-11-20T19:00:00Z")

        let now = at("2026-11-01T00:00:00Z")
        let sorted = Commitment.live([sameTimeHeld, earlier, sameTimeLocked, shorter], from: now, now: now)
        XCTAssertEqual(sorted.map(\.range.lowerBound.timeIntervalSince1970).first,
                       earlier.range.lowerBound.timeIntervalSince1970, "earliest start first")
        // Same start: the shorter one ends first, so it comes first.
        XCTAssertEqual(sorted[1].id, shorter.id)
        // Same start AND end: Locked outranks Held.
        XCTAssertEqual(sorted[2].id, sameTimeLocked.id)
        XCTAssertEqual(sorted[3].id, sameTimeHeld.id)

        // Total: sorting a shuffled copy any number of times lands in the same order.
        for _ in 0..<20 {
            let reshuffled = Commitment.live([shorter, sameTimeHeld, sameTimeLocked, earlier].shuffled(),
                                             from: now, now: now)
            XCTAssertEqual(reshuffled.map(\.id), sorted.map(\.id))
        }
    }

    /// protects=two commitments differing only by id order deterministically; fails_when=the id key
    /// is removed and the sort becomes unstable; no_claim=which id sorts first, only that it is fixed.
    func testIdenticalCommitmentsOrderDeterministically() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let now = at("2026-11-01T00:00:00Z")
        let one = commitment(.busy, "2026-11-20T18:00:00Z", "2026-11-20T20:00:00Z", id: a)
        let two = commitment(.busy, "2026-11-20T18:00:00Z", "2026-11-20T20:00:00Z", id: b)
        XCTAssertEqual(Commitment.live([one, two], from: now, now: now).map(\.id), [a, b])
        XCTAssertEqual(Commitment.live([two, one], from: now, now: now).map(\.id), [a, b])
    }

    // MARK: - Day grouping

    /// protects=an overnight commitment is grouped under the evening it began, once, not twice;
    /// fails_when=grouping keys on the end date or emits a row per day spanned; no_claim=how the
    /// view renders a commitment that runs past its own day header.
    func testOvernightCommitmentGroupsUnderTheDayItStarts() {
        let overnight = commitment(.busy, "2026-11-19T22:00:00Z", "2026-11-20T06:00:00Z")
        let days = Commitment.grouped([overnight], calendar: cal)
        XCTAssertEqual(days.count, 1, "listed once, not on both days")
        XCTAssertEqual(days[0].date, cal.startOfDay(for: at("2026-11-19T22:00:00Z")))
    }

    /// protects=commitments collapse into one group per day, in day order, each day's rows sorted;
    /// fails_when=grouping emits a day per commitment (the consecutive-run bug) or loses the sort;
    /// no_claim=timezone handling, covered below.
    func testGroupingCollapsesDaysAndKeepsOrder() {
        let d1a = commitment(.busy, "2026-11-19T09:00:00Z", "2026-11-19T10:00:00Z")
        let d1b = commitment(.locked, "2026-11-19T18:00:00Z", "2026-11-19T19:00:00Z")
        let d2 = commitment(.held, "2026-11-21T12:00:00Z", "2026-11-21T13:00:00Z")

        let days = Commitment.grouped([d2, d1b, d1a], calendar: cal)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].commitments.map(\.id), [d1a.id, d1b.id])
        XCTAssertEqual(days[1].commitments.map(\.id), [d2.id])
        XCTAssertLessThan(days[0].date, days[1].date)
    }

    /// protects=grouping follows the calendar it is handed, so a timezone change regroups rather
    /// than reading a global; fails_when=startOfDay is computed against Calendar.current;
    /// no_claim=that the screen actually re-renders on the notification, which is a view test.
    func testGroupingFollowsTheSuppliedCalendar() {
        // 2026-11-20 06:00Z is the 20th in UTC and still the 19th in Los Angeles (22:00 on the 19th).
        let c = commitment(.busy, "2026-11-20T06:00:00Z", "2026-11-20T07:00:00Z")
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        let utcDay = Commitment.grouped([c], calendar: cal)[0].date
        let laDay = Commitment.grouped([c], calendar: la)[0].date
        XCTAssertNotEqual(utcDay, laDay, "the same instant falls on different days in the two zones")
        XCTAssertEqual(cal.component(.day, from: utcDay), 20)
        XCTAssertEqual(la.component(.day, from: laDay), 19)
    }

    /// protects=an empty list groups to no days rather than one empty day; fails_when=grouping
    /// emits a header for nothing; no_claim=the empty-state copy, which is the view's.
    func testEmptyListGroupsToNothing() {
        XCTAssertTrue(Commitment.grouped([], calendar: cal).isEmpty)
    }

    // MARK: - Words and titles

    /// protects=the three words the row shows; fails_when=a label is reworded in the view instead of
    /// here, so the screen and the VoiceOver label diverge; no_claim=placement or styling.
    func testKindLabels() {
        XCTAssertEqual(CommitmentKind.held.label, "Held")
        XCTAssertEqual(CommitmentKind.locked.label, "Locked")
        XCTAssertEqual(CommitmentKind.busy.label, "Busy")
        XCTAssertEqual(CommitmentKind.allCases.count, 3, "a new kind needs a word and a rank")
    }

    /// protects="a plan I may not name" staying distinguishable from "no plan at all", which the UI
    /// renders differently; fails_when=a nil title is conflated with a nil plan id; no_claim=that the
    /// server authorized correctly, which commitments_test.sql covers.
    func testNamelessPlanIsNotTheSameAsNoPlan() {
        let plan = UUID()
        let nameless = commitment(.locked, "2026-12-20T19:00:00Z", "2026-12-20T22:00:00Z", title: nil, plan: plan)
        let ownBlock = commitment(.busy, "2026-12-21T09:00:00Z", "2026-12-21T10:00:00Z", title: nil, plan: nil)

        XCTAssertNotNil(nameless.sourceProposalID, "there IS a plan behind it")
        XCTAssertNil(nameless.planTitle, "but this viewer may not know its name")
        XCTAssertNil(ownBlock.sourceProposalID)
        XCTAssertNil(ownBlock.planTitle)
        XCTAssertNotEqual(nameless.kind, ownBlock.kind, "and the two read as different kinds")
    }
}
