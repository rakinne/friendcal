// LockSheetModel and ProposalListModel live in the app target; app-hosted only.
#if canImport(FriendCal)
import XCTest
@testable import FriendCal
@testable import FriendCalCore

/// The lock sheet's duration rule (issue #5 D22, design 5.3A).
@MainActor
final class LockSheetModelTests: XCTestCase {
    private func span(_ minutes: Int) -> DateRange {
        let start = HeatmapTests.date(2026, 11, 14, 12)
        return DateRange(lower: start, upper: start.addingTimeInterval(Double(minutes) * 60))
    }

    /// protects=an 80-min overlap enables 1 h and "All · 1 h 20" only, 1.5 h / 2 h / 3 h are disabled,
    /// the default is the longest fitting duration and the window follows the selection; a 5 h span
    /// enables all four plus "All · 5 h" with 2 h as default; an exact 2 h span offers no "All";
    /// fails_when=an overlong segment stays enabled, All appears for a round span, or the default
    /// drifts; no_claim=the segmented control's rendering.
    func testOptionsTable() {
        let short = LockSheetModel(span: span(80))
        XCTAssertEqual(short.options.map(\.label), ["1 h", "1 h 30", "2 h", "3 h", "All · 1 h 20"])
        XCTAssertEqual(short.options.map(\.isEnabled), [true, false, false, false, true])
        XCTAssertEqual(short.selected?.label, "1 h")
        XCTAssertEqual(short.window, span(60))
        short.selectedID = "all"
        XCTAssertEqual(short.window, span(80))
        XCTAssertNil(short.note)
        XCTAssertFalse(short.isTooShort)

        let five = LockSheetModel(span: span(300))
        XCTAssertEqual(five.options.map(\.isEnabled), [true, true, true, true, true])
        XCTAssertEqual(five.options.last?.label, "All · 5 h")
        XCTAssertEqual(five.selected?.label, "2 h")
        XCTAssertEqual(five.window, span(120))

        let exact = LockSheetModel(span: span(120))
        XCTAssertEqual(exact.options.map(\.label), ["1 h", "1 h 30", "2 h", "3 h"])
        XCTAssertEqual(exact.options.map(\.isEnabled), [true, true, true, false])
        XCTAssertEqual(exact.selected?.label, "2 h")

        XCTAssertTrue(LockSheetModel(span: span(45)).isTooShort)
        XCTAssertNil(LockSheetModel(span: span(45)).window)
    }

    /// protects=a snapshot that shrinks the span while the sheet is open re-evaluates the picker: a
    /// now-overlong selection falls back to the longest enabled with the note, a selection that
    /// still fits keeps it, and a longer span clears the note (D22); fails_when=the stale selection
    /// survives or the note is wrong; no_claim=validateLock's clipping (ProposalTests).
    func testShrinkReevaluatesSelection() {
        let model = LockSheetModel(span: span(300))
        model.selectedID = "10800"
        model.update(span: span(80))
        XCTAssertEqual(model.selected?.label, "1 h")
        XCTAssertEqual(model.note, "Overlap changed: now up to 1 h 20")
        model.update(span: span(70))
        XCTAssertEqual(model.selected?.label, "1 h", "still fits: kept")
        XCTAssertNil(model.note)
        model.update(span: span(300))
        XCTAssertEqual(model.selected?.label, "1 h")
        XCTAssertNil(model.note)
    }
}

/// The Invites list order (design 1.7A).
@MainActor
final class ProposalListModelTests: XCTestCase {
    /// protects=locked upcoming plans first (soonest first), then requesting by window start, then
    /// past plans most recent first, with past judged by the locked end or the window end; fails_when=
    /// a past locked plan sorts as upcoming or the groups interleave; no_claim=row rendering.
    func testOrdered() throws {
        let cal = HeatmapTests.calendar
        let now = HeatmapTests.date(2026, 11, 6, 12)
        let fixture = FixtureData.make(.invites, now: now, calendar: cal)
        let store = FixtureData.store(fixture, clock: { now })
        let model = ProposalListModel(store: store, now: { now })
        let exp = expectation(description: "load")
        Task { await model.load(); exp.fulfill() }
        wait(for: [exp], timeout: 2)
        guard case .rows(let rows) = model.state else { return XCTFail("\(model.state)") }
        XCTAssertEqual(rows.map(\.proposal.title), ["Dinner", "Brunch", "Hike", "Movie night"])
        XCTAssertEqual(rows.map(\.isHosting), [false, true, true, false])
        XCTAssertEqual(rows.map { ProposalListModel.isPast($0.proposal, now: now) }, [false, false, true, true])
        XCTAssertEqual(rows.first?.joinedCount, 5)

        let later = HeatmapTests.date(2026, 11, 14, 21)
        XCTAssertEqual(ProposalListModel.ordered(rows, now: later).map(\.proposal.title), ["Brunch", "Dinner", "Hike", "Movie night"], "the dinner ended at 20:00")
    }
}
#endif
