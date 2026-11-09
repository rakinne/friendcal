import XCTest
@testable import FriendCalCore

/// Roster (X1, X2) and selection (X6, X10) rules, plus the Share text (X9).
/// Fixed New York calendar; 2026-11-09 is a Monday.
final class HeatmapRosterTests: XCTestCase {
    private let proposalID = UUID()
    private let alice = UUID(), bob = UUID(), cara = UUID(), dan = UUID(), eve = UUID()
    private let now = HeatmapTests.date(2026, 11, 1, 0)

    private func mon(_ h: Int, _ m: Int = 0) -> Date { HeatmapTests.date(2026, 11, 9, h, m) }
    private func slot(_ user: UUID, _ from: Date, _ to: Date) -> AvailabilitySlot {
        AvailabilitySlot(userID: user, range: DateRange(lower: from, upper: to), sourceProposalID: proposalID, state: .softHold)
    }
    private func build(_ slots: [AvailabilitySlot], recipients: [UUID], window: DateRange? = nil) -> [HeatmapWeek] {
        HeatmapBuilder.weeks(slots: slots, window: window ?? DateRange(lower: mon(0), upper: HeatmapTests.date(2026, 11, 16, 0)),
                             recipientIDs: recipients, proposalID: proposalID, now: now, calendar: HeatmapTests.calendar)
    }

    /// protects=each recipient's chip status in a cell; fails_when=a status rule is swapped (e.g. a
    /// later-starting slot reads maybe, a missing slot reads anything but busy, or a non-recipient
    /// appears); no_claim=how chips render; slots are hand-built, not from Supabase.
    func testRosterTable() {
        let slots = [
            slot(alice, mon(12), mon(14)),          // covers the 12:00-14:00 common window
            slot(bob, mon(12), mon(14)),
            slot(cara, mon(15), mon(16)),           // starts after the window start
            slot(dan, mon(12), mon(12, 30)),        // in the cell, misses the window, not later
            slot(UUID(), mon(12), mon(17)),         // non-recipient: ignored
        ]
        let cell = build(slots, recipients: [alice, bob, cara, dan, eve])[0].cell(dayIndex: 0, daypart: .afternoon)
        XCTAssertEqual(cell.commonWindow, DateRange(lower: mon(12), upper: mon(14)))
        XCTAssertEqual(cell.roster, [alice: .free, bob: .free, cara: .after(mon(15)), dan: .maybe, eve: .busy])
    }

    /// protects=after(N) when nobody shares an hour; fails_when=the anchor ignores the nil window
    /// and a 13:00 start reads maybe; no_claim=chip wording.
    func testAfterAnchorsOnCellStartWithoutCommonWindow() {
        let cell = build([slot(alice, mon(13), mon(13, 30)), slot(bob, mon(12), mon(12, 20))], recipients: [alice, bob])[0]
            .cell(dayIndex: 0, daypart: .afternoon)
        XCTAssertNil(cell.commonWindow)
        XCTAssertEqual(cell.roster, [alice: .after(mon(13)), bob: .maybe])
    }

    /// protects=chips agree with the cell number ("13 free" means 13 free chips); fails_when=any
    /// enabled cell's free count differs from commonCount or a recipient is missing from the roster;
    /// no_claim=disabled cells (their roster is empty by design).
    func testFreeCountEqualsCommonCountInEveryCell() {
        let recipients = [alice, bob, cara, dan, eve]
        let slots = [
            slot(alice, mon(8), mon(10, 30)), slot(bob, mon(9), mon(11)), slot(cara, mon(9), mon(12)),
            slot(dan, mon(11), mon(13)), slot(eve, mon(18), mon(22)), slot(alice, mon(19), mon(20)),
            slot(bob, mon(12, 30), mon(13, 15)), slot(cara, HeatmapTests.date(2026, 11, 14, 13), HeatmapTests.date(2026, 11, 14, 16)),
        ]
        for cell in build(slots, recipients: recipients)[0].cells where cell.isEnabled {
            XCTAssertEqual(cell.roster.values.filter { $0 == .free }.count, cell.commonCount, "\(cell.id)")
            XCTAssertEqual(Set(cell.roster.keys), Set(recipients))
        }
    }

    // MARK: Selection (X6, X10)

    /// protects=what is selected and whether Share is enabled; fails_when=selection survives a page
    /// change, lands on a disabled cell, invents a selection in a no-best week, drops a manual pick
    /// of a 0 cell, or Share enables on a 0-count cell; no_claim=the UI wiring (UI tests, T7/T13).
    func testSelectionTable() {
        // Window opens Monday 14:30, so Monday morning is disabled in week 1.
        let window = DateRange(lower: mon(14, 30), upper: HeatmapTests.date(2026, 11, 23, 0))
        let sat = HeatmapTests.date(2026, 11, 14, 12)
        let tue2 = HeatmapTests.date(2026, 11, 17, 18)
        let slots = [slot(alice, sat, sat.addingTimeInterval(3 * 3600)), slot(bob, sat, sat.addingTimeInterval(2 * 3600)),
                     slot(alice, tue2, tue2.addingTimeInterval(7200))]
        let weeks = build(slots, recipients: [alice, bob], window: window)
        let week1 = weeks[0], week2 = weeks[1]
        let satAfternoon = week1.cell(dayIndex: 5, daypart: .afternoon)
        let zeroCell = week1.cell(dayIndex: 2, daypart: .morning)
        XCTAssertTrue(satAfternoon.isBest)

        // load -> best
        XCTAssertEqual(HeatmapSelection.resolve(current: nil, week: week1), satAfternoon.id)
        // page change -> that week's best
        XCTAssertEqual(HeatmapSelection.resolve(current: satAfternoon.id, week: week2), week2.cell(dayIndex: 1, daypart: .evening).id)
        // selected cell disabled -> best
        XCTAssertEqual(HeatmapSelection.resolve(current: week1.cell(dayIndex: 0, daypart: .morning).id, week: week1), satAfternoon.id)
        // no best -> nothing selected, Share disabled
        let empty = build([], recipients: [alice, bob], window: window)[0]
        XCTAssertNil(HeatmapSelection.resolve(current: nil, week: empty))
        XCTAssertFalse(HeatmapSelection.canShare(nil))
        // tap a 0 cell -> stays selected, Share disabled
        XCTAssertEqual(HeatmapSelection.resolve(current: zeroCell.id, week: week1), zeroCell.id)
        XCTAssertFalse(HeatmapSelection.canShare(zeroCell))
        XCTAssertTrue(HeatmapSelection.canShare(satAfternoon))
        // selected cell drops to 0 after a rebuild -> stays selected, Share disabled
        let rebuilt = build([], recipients: [alice, bob], window: window)[0]
        XCTAssertEqual(HeatmapSelection.resolve(current: satAfternoon.id, week: rebuilt), satAfternoon.id)
        XCTAssertFalse(HeatmapSelection.canShare(rebuilt.cells.first { $0.id == satAfternoon.id }))
    }

    // MARK: Share text (X9)

    /// protects=the message friends receive names the date and shared hours; fails_when=the date,
    /// window, counts or AM/PM collapsing change, or a 0-count cell yields text; no_claim=other
    /// locales (en_US only).
    func testShareTextNamesDateAndCommonWindow() {
        let sat = HeatmapTests.date(2026, 11, 14, 10)
        let window = DateRange(lower: sat, upper: sat.addingTimeInterval(90 * 60))
        let cell = HeatmapCell(day: HeatmapTests.date(2026, 11, 14, 0), daypart: .morning, interval: window, freeCount: 13, commonCount: 13, commonWindow: window, total: 15)
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ShareText.format(title: "Brunch", cell: cell, calendar: HeatmapTests.calendar, locale: en),
                       "Brunch? Sat, Nov 14 · 10:00-11:30 AM works for 13 of 15")

        let across = DateRange(lower: sat.addingTimeInterval(5400), upper: sat.addingTimeInterval(4 * 3600))
        let noon = HeatmapCell(day: cell.day, daypart: .afternoon, interval: across, freeCount: 2, commonCount: 2, commonWindow: across, total: 15)
        XCTAssertEqual(ShareText.format(title: "Brunch", cell: noon, calendar: HeatmapTests.calendar, locale: en),
                       "Brunch? Sat, Nov 14 · 11:30 AM-2:00 PM works for 2 of 15")

        let zero = HeatmapCell(day: cell.day, daypart: .evening, interval: window, freeCount: 1, commonCount: 0, commonWindow: nil, total: 15)
        XCTAssertNil(ShareText.format(title: "Brunch", cell: zero, calendar: HeatmapTests.calendar, locale: en))
    }

    /// protects=the invite message carries the "?" title, the ask and the link (design 3.5A) and
    /// Home's locked share names the date and window with no "?" (2.2A, 2.1A), both through
    /// Proposal.displayTitle; fails_when=either surface grows a second "?" or loses the link/window;
    /// no_claim=link tappability in Messages (DT11, device).
    func testInviteAndLockedShareText() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000900")!
        XCTAssertEqual(ShareText.invite(title: "Brunch", url: DeepLink.proposal(id).url),
                       "Brunch? Mark when you're free in FriendCal: friendcal://proposal/00000000-0000-0000-0000-000000000900")
        let sat = HeatmapTests.date(2026, 11, 14, 10)
        XCTAssertEqual(ShareText.locked(title: "Brunch", window: DateRange(lower: sat, upper: sat.addingTimeInterval(7200)), calendar: HeatmapTests.calendar, locale: Locale(identifier: "en_US")),
                       "Brunch is locked: Sat, Nov 14 · 10:00 AM-12:00 PM")
        // protects=the winner suffix (design PL-7); fails_when=a place is dropped or appended without " at ";
        // no_claim=names that need escaping, which share text does not do.
        XCTAssertEqual(ShareText.locked(title: "Brunch", window: DateRange(lower: sat, upper: sat.addingTimeInterval(7200)), calendar: HeatmapTests.calendar, locale: Locale(identifier: "en_US"), place: "Cafe Lola"),
                       "Brunch is locked: Sat, Nov 14 · 10:00 AM-12:00 PM at Cafe Lola")
    }

    /// protects=the one set of date formatters the invite, sheets and rows use; fails_when=a day,
    /// time range, day range, duration or daypart string drifts (en_US); no_claim=other locales.
    func testDateTextTable() {
        let cal = HeatmapTests.calendar, en = Locale(identifier: "en_US")
        let sat10 = HeatmapTests.date(2026, 11, 14, 10)
        XCTAssertEqual(DateText.day(sat10, calendar: cal, locale: en), "Sat, Nov 14")
        XCTAssertEqual(DateText.weekday(sat10, calendar: cal, locale: en), "Saturday")
        XCTAssertEqual(DateText.timeRange(DateRange(lower: sat10, upper: sat10.addingTimeInterval(7200)), calendar: cal, locale: en), "10:00 AM–12:00 PM")
        XCTAssertEqual(DateText.timeRange(DateRange(lower: sat10, upper: sat10.addingTimeInterval(5400)), calendar: cal, locale: en), "10:00–11:30 AM")
        XCTAssertEqual(DateText.dayRange(DateRange(lower: HeatmapTests.date(2026, 11, 9, 0), upper: HeatmapTests.date(2026, 11, 22, 23)), calendar: cal, locale: en), "Nov 9–22")
        XCTAssertEqual(DateText.dayRange(DateRange(lower: HeatmapTests.date(2026, 11, 30, 0), upper: HeatmapTests.date(2026, 12, 6, 0)), calendar: cal, locale: en), "Nov 30–Dec 6")
        XCTAssertEqual(DateText.duration(7200), "2 h")
        XCTAssertEqual(DateText.duration(5400), "1 h 30")
        XCTAssertEqual(DateText.duration(4800), "1 h 20")
        XCTAssertEqual(DateText.duration(2700), "45 min")
        XCTAssertEqual(DateText.dayPart(day: cal.startOfDay(for: sat10), daypart: .morning, calendar: cal, locale: en), "Sat morning")
        XCTAssertEqual(DateText.dayPart(day: cal.startOfDay(for: sat10), daypart: .afternoon, calendar: cal, locale: en, long: true), "Saturday afternoon")
    }
}
