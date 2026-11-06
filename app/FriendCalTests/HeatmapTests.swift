import XCTest
@testable import FriendCalCore

/// HeatmapBuilder rules (issue #4 D6, D9-D13). Fixed New York calendar so midnight and DST
/// cases don't depend on the simulator's timezone. 2026-11-09 is a Monday; 2026-11-01 is the
/// fall-back DST Sunday.
final class HeatmapTests: XCTestCase {
    private let proposalID = UUID()
    private let alice = UUID(), bob = UUID(), cara = UUID()
    private lazy var recipients = [alice, bob, cara]
    private let now = HeatmapTests.date(2026, 11, 1, 0, 0)

    static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.firstWeekday = 2
        return cal
    }()

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// Monday Nov 9 2026 at h:min.
    private func mon(_ h: Int, _ min: Int = 0) -> Date { Self.date(2026, 11, 9, h, min) }
    private func tue(_ h: Int, _ min: Int = 0) -> Date { Self.date(2026, 11, 10, h, min) }
    private var weekWindow: DateRange { DateRange(lower: mon(0), upper: Self.date(2026, 11, 16, 0)) }

    private func slot(_ user: UUID, _ from: Date, _ to: Date, proposal: UUID? = nil, state: AvailabilityState = .softHold, expires: Date? = nil) -> AvailabilitySlot {
        AvailabilitySlot(userID: user, range: DateRange(lower: from, upper: to), sourceProposalID: proposal ?? proposalID, state: state, expiresAt: expires)
    }

    private func build(_ slots: [AvailabilitySlot], window: DateRange? = nil, calendar: Calendar = HeatmapTests.calendar) -> [HeatmapWeek] {
        HeatmapBuilder.weeks(slots: slots, window: window ?? weekWindow, recipientIDs: recipients, proposalID: proposalID, now: now, calendar: calendar)
    }

    // MARK: Grid shape

    func testWeekIsMondayFirstWith21Cells() {
        var sundayFirst = Self.calendar
        sundayFirst.firstWeekday = 1
        let weeks = build([], calendar: sundayFirst)
        XCTAssertEqual(weeks.count, 1)
        XCTAssertEqual(weeks[0].weekStart, mon(0))
        XCTAssertEqual(weeks[0].cells.count, 21)
        XCTAssertEqual(weeks[0].cell(dayIndex: 6, daypart: .evening).day, Self.date(2026, 11, 15, 0))
        XCTAssertTrue(weeks[0].cells.allSatisfy { $0.total == 3 })
    }

    func testWindowSpanningWeeksYieldsEachWeek() {
        let window = DateRange(lower: Self.date(2026, 11, 13, 9), upper: Self.date(2026, 11, 24, 9))
        XCTAssertEqual(build([], window: window).map(\.weekStart), [mon(0), Self.date(2026, 11, 16, 0), Self.date(2026, 11, 23, 0)])
    }

    // MARK: Bucketing (run 1, D10)

    func testIntersectsNeedsSharedTimeButOverlapsAcceptsTouching() {
        let morning = DateRange(lower: mon(6), upper: mon(12))
        let afternoon = DateRange(lower: mon(12), upper: mon(17))
        let instant = DateRange(lower: mon(10), upper: mon(10))
        XCTAssertFalse(morning.intersects(afternoon))
        XCTAssertTrue(morning.overlaps(afternoon))
        XCTAssertFalse(instant.intersects(morning))
        XCTAssertFalse(morning.intersects(instant))
        XCTAssertTrue(morning.intersects(DateRange(lower: mon(11, 59), upper: mon(13))))
    }

    func testBucketingUsesPositiveDurationIntersection() {
        let rows: [(String, Date, Date, [Daypart])] = [
            ("11:30-13:00 spans morning and afternoon", mon(11, 30), mon(13), [.morning, .afternoon]),
            ("02:00-04:00 counts nowhere", mon(2), mon(4), []),
            ("ends exactly 12:00, not afternoon", mon(6), mon(12), [.morning]),
            ("starts exactly 17:00, not afternoon", mon(17), mon(19), [.evening]),
            ("zero duration counts nowhere", mon(10), mon(10), []),
        ]
        for (name, from, to, expected) in rows {
            let week = build([slot(alice, from, to)])[0]
            let hit = Daypart.allCases.filter { week.cell(dayIndex: 0, daypart: $0).freeCount == 1 }
            XCTAssertEqual(hit, expected, name)
        }
    }

    func testFriendWithTwoSlotsInOneCellCountsOnce() {
        let cell = build([slot(alice, mon(8), mon(10)), slot(alice, mon(9), mon(11))])[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(cell.freeCount, 1)
        XCTAssertEqual(cell.commonCount, 1)
        XCTAssertEqual(cell.commonWindow, DateRange(lower: mon(8), upper: mon(11)))
    }

    func testDSTDayBucketsByLocalClock() {
        // Week of Mon Oct 26 - Sun Nov 1 2026; Nov 1 is 25 hours long.
        let window = DateRange(lower: Self.date(2026, 10, 26, 0), upper: Self.date(2026, 11, 2, 0))
        let sunday = build([slot(alice, Self.date(2026, 11, 1, 18), Self.date(2026, 11, 1, 20))], window: window)
        XCTAssertEqual(sunday.count, 1)
        let evening = sunday[0].cell(dayIndex: 6, daypart: .evening)
        XCTAssertEqual(evening.day, Self.calendar.startOfDay(for: Self.date(2026, 11, 1, 12)))
        XCTAssertEqual(evening.interval, DateRange(lower: Self.date(2026, 11, 1, 17), upper: Self.date(2026, 11, 1, 23)))
        XCTAssertEqual(evening.commonCount, 1)
        XCTAssertEqual(sunday[0].cells.filter { $0.commonCount > 0 }.count, 1)
    }

    // MARK: Eligibility (run 1, D9; D8 expired softHold)

    func testOnlyThisProposalsUnexpiredRecipientSoftHoldsCount() {
        let stranger = UUID()
        let slots = [
            slot(alice, mon(9), mon(11)),                                   // counts
            slot(stranger, mon(9), mon(11)),                                // not a recipient
            slot(bob, mon(9), mon(11), proposal: UUID()),                   // other proposal
            slot(cara, mon(9), mon(11), state: .busy),                      // not a softHold
            slot(bob, mon(9), mon(11), expires: now.addingTimeInterval(-1)), // expired before now
            slot(cara, mon(9), mon(11), expires: now),                      // expires exactly at now
        ]
        let cell = build(slots)[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(cell.freeCount, 1)
        XCTAssertEqual(cell.commonCount, 1)
        XCTAssertEqual(cell.total, 3)
    }

    func testHoldExpiringAfterNowCounts() {
        let cell = build([slot(alice, mon(9), mon(11), expires: now.addingTimeInterval(60))])[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(cell.commonCount, 1)
    }

    // MARK: Window edges (run 1, D11)

    func testWindowStartingMidAfternoonClipsEdgeCells() throws {
        let window = DateRange(lower: mon(14, 30), upper: Self.date(2026, 11, 16, 0))
        let week = build([slot(alice, mon(14), mon(17))], window: window)[0]
        let morning = week.cell(dayIndex: 0, daypart: .morning)
        let afternoon = week.cell(dayIndex: 0, daypart: .afternoon)
        XCTAssertFalse(morning.isEnabled)
        XCTAssertNil(morning.ramp)
        XCTAssertEqual(afternoon.interval, DateRange(lower: mon(14, 30), upper: mon(17)))
        XCTAssertEqual(afternoon.lockTarget, mon(14, 30))
    }

    // MARK: Common window (run 1, D12)

    func testCommonWindowRules() {
        // 06-07 and 11-12: each alone has an hour, they never share one.
        let apart = build([slot(alice, mon(6), mon(7)), slot(bob, mon(11), mon(12))])[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(apart.freeCount, 2)
        XCTAssertEqual(apart.commonCount, 1)
        XCTAssertEqual(apart.commonWindow, DateRange(lower: mon(6), upper: mon(7)))

        // Shared 09:00-10:30.
        let shared = build([slot(alice, mon(8), mon(10, 30)), slot(bob, mon(9), mon(11))])[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(shared.commonCount, 2)
        XCTAssertEqual(shared.commonWindow, DateRange(lower: mon(9), upper: mon(10, 30)))
        XCTAssertEqual(shared.lockTarget, mon(9))

        // Shared 09:00-09:45 is under 60 minutes.
        let short = build([slot(alice, mon(8), mon(9, 45)), slot(bob, mon(9), mon(11))])[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(short.commonCount, 1)

        // A lone 45-minute slot shares nothing.
        let tiny = build([slot(alice, mon(9), mon(9, 45))])[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(tiny.freeCount, 1)
        XCTAssertEqual(tiny.commonCount, 0)
        XCTAssertNil(tiny.commonWindow)
    }

    func testLockUsesCommonCountAndTarget() throws {
        let svc = ProposalService()
        svc.quorumThreshold = 0.8
        var proposal = Proposal(id: proposalID, title: "Brunch", window: weekWindow, createdBy: alice, distribution: Distribution(mode: .newGroup, recipientIDs: recipients))

        let apart = build([slot(alice, mon(6), mon(7)), slot(bob, mon(11), mon(12)), slot(cara, mon(11), mon(12))])[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(apart.freeCount, 3)
        XCTAssertThrowsError(try svc.lock(&proposal, to: apart) { _, _ in [] })

        let shared = build([slot(alice, mon(8), mon(10, 30)), slot(bob, mon(9), mon(11)), slot(cara, mon(9), mon(12))])[0].cell(dayIndex: 0, daypart: .morning)
        try svc.lock(&proposal, to: shared) { _, _ in [] }
        XCTAssertEqual(proposal.status, .locked)
        XCTAssertEqual(proposal.lockedDate, mon(9))
    }

    // MARK: Best cell and ramp (run 1, D13)

    func testBestRanksByCommonCountNotFreeCount() {
        let week = build([
            slot(alice, mon(6), mon(7)), slot(bob, mon(11), mon(12)),       // Mon morning: free 2, common 1
            slot(alice, tue(9), tue(11)), slot(bob, tue(9), tue(11)),       // Tue morning: common 2
        ])[0]
        XCTAssertEqual(week.best?.id, week.cell(dayIndex: 1, daypart: .morning).id)
        XCTAssertEqual(week.cells.filter(\.isBest).count, 1)
    }

    func testBestTieGoesToEarliestDayThenDaypart() {
        let byDay = build([slot(alice, tue(9), tue(11)), slot(bob, mon(18), mon(20))])[0]
        XCTAssertEqual(byDay.best?.id, byDay.cell(dayIndex: 0, daypart: .evening).id)

        let byDaypart = build([slot(alice, mon(18), mon(20)), slot(bob, mon(13), mon(15))])[0]
        XCTAssertEqual(byDaypart.best?.id, byDaypart.cell(dayIndex: 0, daypart: .afternoon).id)
    }

    func testAllZeroWeekHasNoBest() {
        XCTAssertNil(build([slot(alice, mon(9), mon(9, 30))])[0].best)
    }

    func testRampThresholds() {
        let rows: [(Double, HeatmapRamp)] = [
            (0, .peachLight), (0.2499, .peachLight), (0.25, .peach), (0.4999, .peach),
            (0.5, .orange), (0.7499, .orange), (0.75, .primary), (1, .primary),
        ]
        for (coverage, ramp) in rows { XCTAssertEqual(HeatmapRamp(coverage: coverage), ramp, "\(coverage)") }

        let thirteenOfFifteen = HeatmapCell(day: mon(0), daypart: .morning, interval: weekWindow, freeCount: 13, commonCount: 13, commonWindow: weekWindow, total: 15)
        XCTAssertEqual(thirteenOfFifteen.ramp, .primary)
    }

    func testZeroRecipientsHasZeroCoverage() {
        let weeks = HeatmapBuilder.weeks(slots: [], window: weekWindow, recipientIDs: [], proposalID: proposalID, now: now, calendar: Self.calendar)
        let cell = weeks[0].cell(dayIndex: 0, daypart: .morning)
        XCTAssertEqual(cell.total, 0)
        XCTAssertEqual(cell.coverage, 0)
        XCTAssertEqual(cell.ramp, .peachLight)
    }
}
