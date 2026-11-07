import XCTest
@testable import FriendCalCore

/// The create form's pure rules (issue #5 D4, D13, design 5.4A). Fixed New York calendar.
final class ProposalDraftTests: XCTestCase {
    private let cal = HeatmapTests.calendar
    private func d(_ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date { HeatmapTests.date(2026, m, day, h, min) }

    /// protects=the default is next Monday for two whole weeks with 8 people and a blank title that
    /// reads "Brunch"; fails_when=today's Monday counts as "next", the span is not 14 days, or the
    /// defaults drift; no_claim=the DatePicker presentation.
    func testDefaultIsNextMondayForTwoWeeks() {
        let fromWednesday = ProposalDraft.default(now: d(11, 4, 15), calendar: cal)
        XCTAssertEqual(fromWednesday.from, d(11, 9))
        XCTAssertEqual(fromWednesday.to, d(11, 22))
        XCTAssertEqual(fromWednesday.dayCount(calendar: cal), 14)
        XCTAssertEqual(fromWednesday.expectedCount, 8)
        XCTAssertEqual(fromWednesday.cleanTitle, "Brunch")
        XCTAssertEqual(ProposalDraft.default(now: d(11, 9, 9), calendar: cal).from, d(11, 16), "a Monday picks the following Monday")
        XCTAssertEqual(ProposalDraft.default(now: d(11, 8, 23), calendar: cal).from, d(11, 9), "a Sunday picks tomorrow")
    }

    /// protects=dates are date-only: From snaps to the start of its day and To to the last second of
    /// its day, so the heatmap's last evening cell is inside the window; fails_when=snapping is
    /// dropped or To snaps to midnight (an empty last day); no_claim=none beyond protects.
    func testWindowSnapsToDayBounds() throws {
        let draft = ProposalDraft(from: d(11, 9, 14, 35), to: d(11, 22, 9, 5))
        let window = try draft.validate(calendar: cal).window
        XCTAssertEqual(window.lowerBound, d(11, 9))
        XCTAssertEqual(window.upperBound, d(11, 23).addingTimeInterval(-1))
        let sameDay = ProposalDraft(from: d(11, 9, 18), to: d(11, 9, 7))
        XCTAssertEqual(sameDay.dayCount(calendar: cal), 1)
        XCTAssertEqual(try sameDay.validate(calendar: cal).window, DateRange(lower: d(11, 9), upper: d(11, 10).addingTimeInterval(-1)))
    }

    /// protects=the 45-day bound counts calendar days of the snapped values, inclusive; fails_when=45
    /// days fail, 46 pass, or the count uses seconds / 86400 across a DST change; no_claim=none beyond protects.
    func testFortyFiveDayBoundOnSnappedDays() {
        XCTAssertNoThrow(try ProposalDraft(from: d(11, 9), to: d(12, 23, 23)).validate(calendar: cal), "45 days")
        XCTAssertThrowsError(try ProposalDraft(from: d(11, 9), to: d(12, 24)).validate(calendar: cal)) { err in
            XCTAssertEqual(err as? ProposalDraft.ValidationError, .tooLong(days: 46))
        }
        // Across the fall-back Sunday (Nov 1 is 25 hours long): still whole days.
        let dst = ProposalDraft(from: d(10, 26), to: d(11, 8))
        XCTAssertEqual(dst.dayCount(calendar: cal), 14)
        XCTAssertEqual(dst.window(calendar: cal).upperBound, d(11, 9).addingTimeInterval(-1))
    }

    /// protects=end before start and fewer than 2 people are refused, and each error is listed per
    /// field for inline presentation; fails_when=a bound flips or an error is swallowed; no_claim=copy.
    func testRefusals() {
        XCTAssertThrowsError(try ProposalDraft(from: d(11, 9), to: d(11, 8)).validate(calendar: cal)) { err in
            XCTAssertEqual(err as? ProposalDraft.ValidationError, .endBeforeStart)
        }
        XCTAssertThrowsError(try ProposalDraft(from: d(11, 9), to: d(11, 10), expectedCount: 1).validate(calendar: cal)) { err in
            XCTAssertEqual(err as? ProposalDraft.ValidationError, .tooFewPeople)
        }
        XCTAssertNoThrow(try ProposalDraft(from: d(11, 9), to: d(11, 10), expectedCount: 2).validate(calendar: cal))
        let both = ProposalDraft(from: d(11, 9), to: d(11, 8), expectedCount: 0)
        XCTAssertEqual(both.errors(calendar: cal), [.endBeforeStart, .tooFewPeople])
        XCTAssertEqual(ProposalDraft(from: d(11, 9), to: d(11, 10)).errors(calendar: cal), [])
    }

    /// protects=the stored title never carries the "?" the app appends (design 2.1A) and blank means
    /// "Brunch"; fails_when=a typed "?" doubles up on the invite or a blank title persists;
    /// no_claim=none beyond protects.
    func testTitleIsCleanedAndDefaulted() throws {
        for (typed, stored) in [("", "Brunch"), ("   ", "Brunch"), ("Brunch?", "Brunch"), ("  Dinner ??  ", "Dinner"), ("Sunday Brunch", "Sunday Brunch")] {
            XCTAssertEqual(ProposalDraft(title: typed, from: d(11, 9), to: d(11, 10)).cleanTitle, stored, "'\(typed)'")
        }
        XCTAssertEqual(try ProposalDraft(title: "Brunch?", from: d(11, 9), to: d(11, 10)).validate(calendar: cal).title, "Brunch")
        XCTAssertEqual(Proposal.displayTitle("Brunch", isLocked: false), "Brunch?")
        XCTAssertEqual(Proposal.displayTitle("Brunch", isLocked: true), "Brunch")
    }

    /// protects=editing prefills from the row and the row's expected count survives a round trip;
    /// fails_when=the edit draft drops the window or headcount; no_claim=the store's edit rules
    /// (InMemoryProposalStoreTests).
    func testEditingPrefillsFromTheProposal() {
        let p = Proposal(id: UUID(), title: "Dinner", window: DateRange(lower: d(11, 9), upper: d(11, 23).addingTimeInterval(-1)),
                         createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID()]), expectedCount: 6)
        let draft = ProposalDraft(editing: p)
        XCTAssertEqual(draft.title, "Dinner")
        XCTAssertEqual(draft.expectedCount, 6)
        XCTAssertEqual(draft.window(calendar: cal), p.window)
    }
}
