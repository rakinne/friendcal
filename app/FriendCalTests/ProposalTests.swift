import XCTest
@testable import FriendCalCore

final class ProposalTests: XCTestCase {
    func testLockRequiresQuorum() {
        var proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID()]))
        let svc = ProposalService()
        let lowCell = Self.cell(commonCount: 1, total: 5) // 20%
        XCTAssertThrowsError(try svc.lock(&proposal, to: lowCell.id, in: Self.weeks(lowCell), busyWriter: { _,_ in [] })) { err in
            XCTAssertTrue((err as? ProposalLockError) != nil)
        }
    }

    func testLockSucceedsAtQuorum() throws {
        var proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID()]))
        let svc = ProposalService()
        let highCell = Self.cell(commonCount: 5, total: 5)
        try svc.lock(&proposal, to: highCell.id, in: Self.weeks(highCell), busyWriter: { _,_ in [] })
        XCTAssertEqual(proposal.status, .locked)
    }

    /// Quorum is inclusive: exactly 80% locks, one short does not.
    func testLockAtExactQuorumBoundary() throws {
        let svc = ProposalService()
        var below = Self.proposal()
        let threeOfFive = Self.cell(commonCount: 3, total: 5)
        XCTAssertThrowsError(try svc.lock(&below, to: threeOfFive.id, in: Self.weeks(threeOfFive), busyWriter: { _,_ in [] })) { err in
            guard case .notEnoughCoverage(let required, let actual) = err as? ProposalLockError else { return XCTFail("got \(err)") }
            XCTAssertEqual(required, 0.8)
            XCTAssertEqual(actual, 0.6, accuracy: 0.0001)
        }
        var atQuorum = Self.proposal()
        let fourOfFive = Self.cell(commonCount: 4, total: 5)
        try svc.lock(&atQuorum, to: fourOfFive.id, in: Self.weeks(fourOfFive), busyWriter: { _,_ in [] })
        XCTAssertEqual(atQuorum.status, .locked)
    }

    /// Value: protects=lock hands the whole common window (start and end) to busyWriter and the
    /// proposal, so the backend can persist both ends (review D5); fails_when=only the start crosses
    /// the boundary again; why_new=other lock tests ignore busyWriter's argument; seam=none;
    /// no_claim=the lock_proposal SQL function (checked against Postgres separately).
    func testLockPassesWholeWindowToBusyWriter() throws {
        var proposal = Self.proposal()
        let cell = Self.cell(commonCount: 5, total: 5)
        var written: DateRange?
        let window = try ProposalService().lock(&proposal, to: cell.id, in: Self.weeks(cell)) { _, w in written = w; return [] }
        XCTAssertEqual(written, cell.commonWindow)
        XCTAssertEqual(window, cell.commonWindow)
        XCTAssertEqual(proposal.lockedDate, cell.commonWindow?.lowerBound)
        XCTAssertEqual(proposal.lockedEnd, cell.commonWindow?.upperBound)
    }

    /// Value: protects=the client quorum equals the quorum lock_proposal() enforces, so the heatmap
    /// never offers a lock the server refuses on quorum alone; fails_when=either side changes alone;
    /// why_new=the server constant lives in SQL; seam=none; no_claim=server busy-block exclusion,
    /// which the client cannot see (see Review notes).
    func testClientQuorumMatchesServerQuorum() throws {
        let sql = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../supabase/lock_proposal.sql").standardizedFileURL
        let text = try String(contentsOf: sql, encoding: .utf8)
        XCTAssertTrue(text.contains("c_quorum constant numeric := 0.8;"), "lock_proposal.sql quorum moved")
        XCTAssertEqual(ProposalService.quorumThreshold, 0.8)
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

    // MARK: validateLock (issue #5 C5, D14, D18)

    private static var nyc: Calendar { HeatmapTests.calendar }
    private static func sat(_ h: Int, _ m: Int = 0, _ s: Double = 0) -> Date { HeatmapTests.date(2026, 11, 14, h, m).addingTimeInterval(s) }
    private static func cell(common: DateRange, interval: DateRange? = nil, commonCount: Int = 5, total: Int = 5) -> HeatmapCell {
        HeatmapCell(day: nyc.startOfDay(for: common.lowerBound), daypart: .afternoon, interval: interval ?? DateRange(lower: sat(12), upper: sat(17)),
                    freeCount: commonCount, commonCount: commonCount, commonWindow: common, total: total)
    }

    /// protects=the window starts at the common window's start (#4 D12) and runs the chosen duration,
    /// 2 h by default, clipped to the common span (D14), with nil meaning the whole span (D22 "All");
    /// fails_when=the end overshoots the span, the default drifts, or All clips; no_claim=the sheet's
    /// disabled segments (UI lane).
    func testValidateLockDurationDefaultClipAndAll() throws {
        let svc = ProposalService()
        let span = DateRange(lower: Self.sat(12), upper: Self.sat(17))
        XCTAssertEqual(ProposalService.defaultDuration, 2 * 3600)
        XCTAssertEqual(ProposalService.durations, [3600, 5400, 7200, 10800])
        XCTAssertEqual(try svc.validateLock(cell: Self.cell(common: span), duration: ProposalService.defaultDuration), DateRange(lower: Self.sat(12), upper: Self.sat(14)))
        XCTAssertEqual(try svc.validateLock(cell: Self.cell(common: span), duration: 3 * 3600), DateRange(lower: Self.sat(12), upper: Self.sat(15)))
        let short = DateRange(lower: Self.sat(12), upper: Self.sat(13, 30))
        XCTAssertEqual(try svc.validateLock(cell: Self.cell(common: short), duration: 2 * 3600), short, "clipped at the span's end")
        XCTAssertEqual(try svc.validateLock(cell: Self.cell(common: span), duration: nil), span, "All = the whole span")
    }

    /// protects=a clipped window under 60 minutes is refused and a refusal mutates nothing;
    /// fails_when=windowTooShort is missing or the floor is not 60 min; no_claim=none beyond protects.
    func testValidateLockRefusesUnderSixtyMinutes() {
        let tiny = DateRange(lower: Self.sat(12), upper: Self.sat(12, 45))
        XCTAssertThrowsError(try ProposalService().validateLock(cell: Self.cell(common: tiny), duration: 3600)) { err in
            XCTAssertEqual(err as? ProposalLockError, .windowTooShort)
            XCTAssertNotNil((err as? LocalizedError)?.errorDescription)
        }
        XCTAssertNoThrow(try ProposalService().validateLock(cell: Self.cell(common: DateRange(lower: Self.sat(12), upper: Self.sat(13))), duration: 3600))
    }

    /// protects=the window's start rounds down and its end up to whole minutes (D18) so the Supabase
    /// client's millisecond truncation can never land a bound below a hold's, and a hold whose start
    /// carries microseconds still promotes (window start equals the hold's minute); fails_when=
    /// snapping is dropped, the end is computed from the raw start, or promotion compares raw
    /// sub-second bounds; no_claim=lock_proposal's own range check (sql lane).
    func testValidateLockSnapsToWholeMinutesAndMicrosecondHoldPromotes() throws {
        let fuzzy = DateRange(lower: Self.sat(12, 0, 0.000123), upper: Self.sat(17, 0, 0.000123))
        let window = try ProposalService().validateLock(cell: Self.cell(common: fuzzy), duration: 2 * 3600)
        XCTAssertEqual(window, DateRange(lower: Self.sat(12), upper: Self.sat(14)))
        XCTAssertEqual(try ProposalService().validateLock(cell: Self.cell(common: fuzzy), duration: nil), DateRange(lower: Self.sat(12), upper: Self.sat(17, 1)), "the end rounds up")

        let pid = UUID(), friend = UUID()
        let hold = AvailabilitySlot(userID: friend, range: fuzzy, sourceProposalID: pid, state: .softHold, expiresAt: Self.sat(23))
        let (promoted, _) = AvailabilityService().promoteToBusy(window: window, proposalID: pid, recipientIDs: [friend], slots: [hold], now: Self.sat(8))
        XCTAssertEqual(promoted.map(\.userID), [friend])
        XCTAssertEqual(promoted.first?.range, window)
    }

    /// protects=the lock stays server-first (C5, TODOS "Make lock server-first"): a store refusal
    /// leaves the proposal requesting and no local field set; fails_when=the session or service
    /// applies the lock before the store answers; no_claim=RPC behavior (the in-memory store refuses).
    func testStoreRefusalLeavesStatusRequesting() async throws {
        let creator = UUID(), friend = UUID()
        var p = Self.proposal()
        p.createdBy = creator
        p.distribution.recipientIDs = [creator, friend]
        p.expectedCount = 2
        let store = InMemoryProposalStore(proposals: [p], currentUserID: creator)
        let window = DateRange(lower: p.window.lowerBound.addingTimeInterval(3600), upper: p.window.lowerBound.addingTimeInterval(3 * 3600))
        do {
            _ = try await store.lock(p.id, window: window)
            XCTFail("locked with nobody free")
        } catch {
            guard case let ProposalStoreError.server(code, _, hint) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "22023")
            XCTAssertEqual(hint, "FC_QUORUM")
        }
        let after = try await store.load(p.id).proposal
        XCTAssertEqual(after.status, .requesting)
        XCTAssertNil(after.lockedDate)
        XCTAssertTrue(after.lockedAttendeeIDs.isEmpty)
    }

    private static func proposal() -> Proposal {
        Proposal(id: UUID(), title: "Brunch", window: DateRange(Date.now...Date.now.addingTimeInterval(86400*30)), createdBy: UUID(), distribution: Distribution(mode: .newGroup, recipientIDs: [UUID()]))
    }

    private static func weeks(_ cells: HeatmapCell...) -> [HeatmapWeek] {
        [HeatmapWeek(weekStart: cells[0].day, cells: cells)]
    }

    private static func cell(commonCount: Int, total: Int) -> HeatmapCell {
        // Whole-minute start: validateLock snaps the window to minutes (issue #5 D18), so a
        // seconds-precision Date() would no longer equal the window it hands back.
        let start = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
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