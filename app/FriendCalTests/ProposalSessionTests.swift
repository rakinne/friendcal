// ProposalSession lives in the app target; SPM builds this folder against FriendCalCore only, so the
// test runs app-hosted under Xcode. The first three tests are HomeModelTests carried unchanged
// (issue #5 D10 regression contract: a type rename only).
#if canImport(FriendCal)
import XCTest
@testable import FriendCal
@testable import FriendCalCore

@MainActor
final class ProposalSessionTests: XCTestCase {
    private let alice = HomeMember(id: UUID(), name: "Alice", isOnline: true, isActive: true)
    private let bob = HomeMember(id: UUID(), name: "Bob", isOnline: true, isActive: false)
    private func mon(_ h: Int, _ m: Int = 0) -> Date { HeatmapTests.date(2026, 11, 9, h, m) }

    /// protects=a hold that expires while Home stays open stops counting at the next refresh, with
    /// no new data (X12), and the selection follows X10; fails_when=refresh(now:) reuses the
    /// launch-time `now`, keeps the expired friend free, mutates the slots, or drops/moves the
    /// selection when the cell falls to 0; no_claim=the 60s timer and scenePhase wiring in
    /// HomeView fire (not driven here); fixture members and slots stand in for Supabase rows.
    func testRefreshPastExpiryDropsFriendWithoutSlotChange() throws {
        let proposal = Proposal(id: UUID(), title: "Brunch", window: DateRange(lower: mon(0), upper: HeatmapTests.date(2026, 11, 16, 0)),
                                createdBy: alice.id, distribution: Distribution(mode: .newGroup, recipientIDs: [alice.id, bob.id]))
        func hold(_ m: HomeMember, expires: Date) -> AvailabilitySlot {
            AvailabilitySlot(userID: m.id, range: DateRange(lower: mon(9), upper: mon(11)), sourceProposalID: proposal.id, state: .softHold, expiresAt: expires)
        }
        let slots = [hold(alice, expires: mon(8, 30)), hold(bob, expires: mon(8))]
        let fixture = HomeFixture(groupName: "Brunch crew", members: [alice, bob], proposal: proposal, slots: slots, lastUpdated: mon(7))
        let model = ProposalSession(fixture: fixture, now: mon(7, 59), calendar: HeatmapTests.calendar)

        let cellID = HeatmapCell.ID(day: mon(0), daypart: .morning)
        XCTAssertEqual(model.selectedCellID, cellID)
        XCTAssertEqual(model.selectedCell?.commonCount, 2)

        model.refresh(now: mon(8, 1)) // Bob's hold expired at 08:00
        XCTAssertEqual(model.slots, slots)
        XCTAssertEqual(model.selectedCellID, cellID)
        XCTAssertEqual(model.selectedCell?.commonCount, 1)
        XCTAssertEqual(model.selectedCell?.roster, [alice.id: .free, bob.id: .busy])
        XCTAssertNotNil(model.shareText)

        model.refresh(now: mon(8, 31)) // Alice's too: the cell drops to 0 and stays selected
        XCTAssertEqual(model.selectedCellID, cellID)
        XCTAssertEqual(model.selectedCell?.commonCount, 0)
        XCTAssertNil(model.visibleWeek?.best)
        XCTAssertNil(model.shareText)
        XCTAssertEqual(model.shareDisabledHint, "Nobody shares an hour here yet")
        XCTAssertEqual(model.lastUpdated, mon(7))
    }
    /// Value: protects=past 10 members the wheel shows 9 faces incl. the active friend plus +N (D36);
    /// fails_when=the active swap, the 10-member cutoff or the overflow count changes;
    /// why_new=UI tests check the drawer, not which faces show; seam=none;
    /// no_claim=face layout on the orbit (FriendsWheel, UI lane only).
    func testWheelKeepsActiveFriendPastNine() {
        func members(_ n: Int, activeAt: Int) -> [HomeMember] {
            (0..<n).map { HomeMember(id: UUID(), name: "M\($0)", isOnline: false, isActive: $0 == activeAt) }
        }
        func model(_ ms: [HomeMember]) -> ProposalSession {
            ProposalSession(fixture: HomeFixture(groupName: "G", members: ms, proposal: nil, slots: [], lastUpdated: mon(7)), now: mon(8), calendar: HeatmapTests.calendar)
        }
        let ten = members(10, activeAt: 9)
        XCTAssertEqual(model(ten).wheel.faces, ten)
        XCTAssertEqual(model(ten).wheel.overflow, 0)

        let twelve = members(12, activeAt: 11)
        let w = model(twelve).wheel
        XCTAssertEqual(w.overflow, 3)
        XCTAssertEqual(w.faces.count, 9)
        XCTAssertEqual(Array(w.faces.prefix(8)), Array(twelve.prefix(8)))
        XCTAssertEqual(w.faces[8], twelve[11])

        let early = members(12, activeAt: 2)
        XCTAssertEqual(model(early).wheel.faces, Array(early.prefix(9)))
    }

    /// Value: protects=no proposal clears weeks/selection and Share says "Pick a time first"; only
    /// enabled cells of the visible week select; unknown weeks are ignored; fails_when=a guard in
    /// refresh/select/showWeek is dropped; why_new=existing test covers expiry only; seam=none;
    /// no_claim=tap and swipe gestures (UI lane).
    func testNoProposalAndSelectionGuards() {
        let empty = ProposalSession(fixture: HomeFixture(groupName: "G", members: [alice], proposal: nil, slots: [], lastUpdated: mon(7)), now: mon(8), calendar: HeatmapTests.calendar)
        XCTAssertTrue(empty.weeks.isEmpty)
        XCTAssertNil(empty.selectedCellID)
        XCTAssertNil(empty.chips)
        XCTAssertEqual(empty.shareDisabledHint, "Pick a time first")

        // Window opens Monday 14:30 and spans two weeks; Monday morning is disabled.
        let proposal = Proposal(id: UUID(), title: "Brunch", window: DateRange(lower: mon(14, 30), upper: HeatmapTests.date(2026, 11, 23, 0)),
                                createdBy: alice.id, distribution: Distribution(mode: .newGroup, recipientIDs: [alice.id]))
        let model = ProposalSession(fixture: HomeFixture(groupName: "G", members: [alice], proposal: proposal, slots: [], lastUpdated: mon(7)), now: mon(8), calendar: HeatmapTests.calendar)
        XCTAssertEqual(model.weeks.count, 2)
        XCTAssertNil(model.selectedCellID)
        model.select(HeatmapCell.ID(day: mon(0), daypart: .morning))
        XCTAssertNil(model.selectedCellID)
        let tueMorning = HeatmapCell.ID(day: HeatmapTests.date(2026, 11, 10, 0), daypart: .morning)
        model.select(tueMorning)
        XCTAssertEqual(model.selectedCellID, tueMorning)
        XCTAssertEqual(model.chips?.map(\.status), [.busy])
        model.select(HeatmapCell.ID(day: HeatmapTests.date(2026, 11, 17, 0), daypart: .morning)) // other week: ignored
        XCTAssertEqual(model.selectedCellID, tueMorning)
        model.showWeek(HeatmapTests.date(2026, 12, 1, 0)) // unknown week: ignored
        XCTAssertEqual(model.visibleWeekID, model.weeks[0].id)
        model.showWeek(model.weeks[1].id)
        XCTAssertEqual(model.visibleWeekID, model.weeks[1].id)
        XCTAssertNil(model.selectedCellID)
    }

    // MARK: Issue #5: the session over the in-memory store

    private let cal = HeatmapTests.calendar
    private let launch = HeatmapTests.date(2026, 11, 6, 12)
    private func session(_ scenario: FixtureScenario, now: Date? = nil) -> ProposalSession {
        ProposalSession(fixture: FixtureData.make(scenario, now: now ?? launch, calendar: cal), now: now ?? launch, calendar: cal)
    }
    private func bestCell(_ s: ProposalSession) throws -> HeatmapCell { try XCTUnwrap(s.lockState?.bestCell) }
    private var satAfternoon: HeatmapCell.ID { HeatmapCell.ID(day: HeatmapTests.date(2026, 11, 14, 0), daypart: .afternoon) }

    /// protects=lockState is derived per fixture: the recipient invite is one short of quorum, the
    /// creator alone reads inviteFriends, a locked plan reads its row (S3, D13, C1); fails_when=the
    /// session feeds the wrong expected count, recipients or status to LockState; no_claim=copy.
    func testLockStateFollowsTheProposal() throws {
        let invite = session(.lockedInvite)
        XCTAssertFalse(invite.isCreator)
        XCTAssertEqual(invite.creatorName, "Sam")
        guard case .requesting(let have, let needed, let total, let joined, let best)? = invite.lockState else { return XCTFail("\(String(describing: invite.lockState))") }
        XCTAssertEqual([have, needed, total, joined], [7, 8, 10, 10])
        XCTAssertEqual(best?.id, satAfternoon)
        XCTAssertEqual(invite.lockState?.caption(creatorName: invite.creatorName, isCreator: invite.isCreator), "Locked until 1 more friend overlaps")
        XCTAssertEqual(invite.total, 10)

        let alone = session(.creatorAlone)
        XCTAssertEqual(alone.lockState, .inviteFriends(expected: 8))
        XCTAssertTrue(alone.isCreator)
        XCTAssertEqual(alone.total, 8)

        let locked = session(.lockedPlan)
        guard case .locked(let window, let attendees, let late)? = locked.lockState else { return XCTFail("not locked") }
        XCTAssertEqual(window, FixtureData.lockedWindow(cal))
        XCTAssertEqual(attendees.count, 8)
        XCTAssertTrue(late.isEmpty)
        XCTAssertEqual(locked.lockedCellID, satAfternoon)
        XCTAssertEqual(locked.attendeeChips?.filter(\.isIn).count, 8)
        XCTAssertEqual(locked.shareText, "Brunch is locked: Sat, Nov 14 · 12:00-2:00 PM")
        XCTAssertFalse(locked.didJustLock, "an already-locked plan never fires the acknowledgment")
    }

    /// protects=a tap writes my hold for the cell's interval expiring at its end (D9, C3) so the
    /// caption reaches quorum, the chips follow the tapped cell (1.5A) and the free line names it
    /// (3.1A); a second tap releases it; fails_when=the hold lands on the wrong range or expiry, the
    /// count does not move, or release leaves a slot; no_claim=the sheet's haptics and toast.
    func testToggleWritesAndReleasesMyHold() async throws {
        let s = session(.lockedInvite)
        let best = try bestCell(s)
        XCTAssertTrue(s.myHoldCellIDs.isEmpty)
        XCTAssertNil(s.freeSummary)
        let toggled1 = await s.toggle(best)
        XCTAssertNil(toggled1)
        XCTAssertEqual(s.myHoldCellIDs, [best.id])
        XCTAssertEqual(s.markFocusCellID, best.id)
        XCTAssertEqual(s.lockState?.isQuorumReached, true)
        XCTAssertEqual(s.lockState?.caption(creatorName: "Sam", isCreator: false), "Enough friends overlap. Waiting for Sam to lock.")
        XCTAssertEqual(s.freeSummary, "Sat afternoon")
        XCTAssertEqual(s.lockState?.linkTitle(hasMyHolds: s.freeSummary != nil), "Update your availability")
        let store = try XCTUnwrap(s.store as? InMemoryProposalStore)
        let mine = store.slots.filter { $0.userID == s.currentUserID }
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine.first?.range, best.interval)
        XCTAssertEqual(mine.first?.expiresAt, best.interval?.upperBound)
        XCTAssertEqual(s.markChips?.first { $0.member.id == s.currentUserID }?.status, .free)

        let toggled2 = await s.toggle(try bestCell(s))
        XCTAssertNil(toggled2)
        XCTAssertTrue(s.myHoldCellIDs.isEmpty)
        XCTAssertEqual(s.lockState?.remaining, 1)
        XCTAssertTrue(store.slots.filter { $0.userID == s.currentUserID }.isEmpty)
    }

    /// protects=a past cell cannot be marked (D9, 5.2A) and a failed save reverts the optimistic hold
    /// with the mapped sentence (2.2A, 2.3A); fails_when=a past tap writes a hold, or the revert or
    /// the message is missing; no_claim=network failure itself (failNext stands in).
    func testTogglePastCellIsIgnoredAndFailureReverts() async throws {
        let later = session(.lockedInvite, now: HeatmapTests.date(2026, 11, 10, 12))
        let tueMorning = try XCTUnwrap(later.visibleWeek?.cells.first { $0.id == HeatmapCell.ID(day: HeatmapTests.date(2026, 11, 10, 0), daypart: .morning) })
        XCTAssertTrue(later.isPast(tueMorning))
        let toggled3 = await later.toggle(tueMorning)
        XCTAssertNil(toggled3)
        XCTAssertTrue(later.myHoldCellIDs.isEmpty)

        let s = session(.lockedInvite)
        let store = try XCTUnwrap(s.store as? InMemoryProposalStore)
        store.failNext[.tapFree] = ProposalStoreError.network("offline")
        let error = await s.toggle(try bestCell(s))
        XCTAssertEqual(error?.message, "Couldn't save your availability. Retry.")
        XCTAssertTrue(s.myHoldCellIDs.isEmpty)
        XCTAssertEqual(s.lockState?.remaining, 1)
        XCTAssertTrue(store.slots.filter { $0.userID == s.currentUserID }.isEmpty)
    }

    /// Value: protects=a second tap on a cell whose save is still in flight is ignored, so the hold the first tap writes stays and no 'plan is gone' error appears (review pass 1); fails_when=toggle() reads the optimistic row as a saved hold and releases an id the store never issued; why_new=testToggle* tap one cell at a time; seam=none; no_claim=the sheet's gesture handling (UI lane)
    func testRapidDoubleToggleIsIgnoredWhileTheFirstWriteIsInFlight() async throws {
        let s = session(.lockedInvite)
        let store = try XCTUnwrap(s.store as? InMemoryProposalStore)
        store.latency = .milliseconds(40)
        let cell = try bestCell(s)
        async let first = s.toggle(cell)
        async let second = s.toggle(cell)
        let (e1, e2) = await (first, second)
        XCTAssertNil(e1)
        XCTAssertNil(e2, "the second tap is ignored, not a failed release")
        XCTAssertTrue(s.myHoldCellIDs.contains(cell.id))
        XCTAssertEqual(store.slots.filter { $0.userID == s.currentUserID }.count, 1, "one hold written, the second tap did not undo it")
    }

    /// Value: protects=a failed release puts back only its own hold, so a mark on another cell made while it was in flight keeps its saved row (review pass 1); fails_when=the revert restores a whole-array snapshot that drops the other cell's optimistic hold; why_new=testTogglePastCellIsIgnoredAndFailureReverts reverts a single mark; seam=none; no_claim=server-side release semantics
    func testFailedReleaseKeepsAnOverlappingMarkOnAnotherCell() async throws {
        let s = session(.lockedInvite)
        let store = try XCTUnwrap(s.store as? InMemoryProposalStore)
        let cells = try XCTUnwrap(s.visibleWeek?.cells.filter { $0.isEnabled && !s.isPast($0) })
        let a = try XCTUnwrap(cells.first), b = try XCTUnwrap(cells.last)
        XCTAssertNotEqual(a.day, b.day)
        let marked = await s.toggle(a)
        XCTAssertNil(marked)
        store.latency = .milliseconds(40)
        store.failNext[.release] = ProposalStoreError.network("offline")
        async let release = s.toggle(a)
        async let mark = s.toggle(b)
        let (releaseError, markError) = await (release, mark)
        XCTAssertEqual(releaseError?.message, "Couldn't save your availability. Retry.")
        XCTAssertNil(markError)
        XCTAssertEqual(s.myHoldCellIDs, [a.id, b.id], "A is back after the failed release; B kept its saved hold")
        XCTAssertEqual(store.slots.filter { $0.userID == s.currentUserID }.count, 2)
    }

    /// protects=lock is server-first (C5, R3): below quorum it throws without touching the plan, a
    /// store refusal leaves it requesting, and a success applies the returned proposal (locked cell,
    /// attendees, share text) and fires the acknowledgment once (3.4A, delta A3); fails_when=the
    /// session marks a lock locally, re-fires on reload, or drops the store's attendees; no_claim=RPC.
    func testLockIsServerFirstAndAcknowledgesOnce() async throws {
        let s = session(.lockedInviteCreator)
        XCTAssertTrue(s.isCreator)
        do { try await s.lock(duration: ProposalService.defaultDuration); XCTFail("locked below quorum") } catch let e as UserFacingError {
            XCTAssertEqual(e.message, "Not enough friends are free anymore. Pick another time.")
        }
        XCTAssertEqual(s.proposal?.status, .requesting)

        let toggled4 = await s.toggle(try bestCell(s))
        XCTAssertNil(toggled4)
        XCTAssertEqual(s.lockState?.isQuorumReached, true)
        XCTAssertEqual(s.lockState?.primaryTitle(isCreator: true, calendar: cal), "Lock Sat afternoon")
        XCTAssertEqual(s.lockSpan, DateRange(lower: HeatmapTests.date(2026, 11, 14, 12), upper: HeatmapTests.date(2026, 11, 14, 17)))
        let store = try XCTUnwrap(s.store as? InMemoryProposalStore)
        store.failNext[.lock] = ProposalStoreError.server(code: "40001", message: "changed", hint: "FC_CHANGED")
        do { try await s.lock(duration: ProposalService.defaultDuration); XCTFail("locked through a refusal") } catch let e as UserFacingError {
            XCTAssertEqual(e.message, "Availability changed while locking. Try again.")
        }
        XCTAssertEqual(s.proposal?.status, .requesting)
        XCTAssertFalse(s.didJustLock)

        try await s.lock(duration: ProposalService.defaultDuration)
        XCTAssertEqual(s.proposal?.status, .locked)
        XCTAssertEqual(s.proposal?.lockedWindow, DateRange(lower: HeatmapTests.date(2026, 11, 14, 12), upper: HeatmapTests.date(2026, 11, 14, 14)))
        XCTAssertEqual(s.proposal?.lockedAttendeeIDs.count, 8)
        XCTAssertEqual(s.lockedCellID, satAfternoon)
        XCTAssertEqual(s.attendeeChips?.filter(\.isIn).count, 8)
        XCTAssertTrue(s.didJustLock)
        XCTAssertTrue(s.consumeLockAcknowledgment())
        XCTAssertFalse(s.consumeLockAcknowledgment())
        await s.reload()
        XCTAssertFalse(s.didJustLock, "a reload of a locked plan must not re-fire")
        XCTAssertEqual(s.proposal?.status, .locked)
        XCTAssertNil(s.lockState?.linkTitle(hasMyHolds: false))
        XCTAssertEqual(s.lockState?.attendanceLine(for: s.currentUserID), "You're in")
    }

    /// protects=run() applies the store's snapshots (D11) so a hold written elsewhere shows up, and
    /// adopt() moves the session to a new plan and loads it; fails_when=the stream is not consumed
    /// or adopt keeps the old plan; no_claim=Realtime delivery.
    func testRunAppliesStoreSnapshotsAndAdoptLoads() async throws {
        let s = session(.lockedInvite)
        let store = try XCTUnwrap(s.store as? InMemoryProposalStore)
        let best = try bestCell(s)
        let runner = Task { await s.run() }
        await Task.yield()
        _ = try await store.tapFree(proposalID: best.id == satAfternoon ? FixtureData.proposalID : FixtureData.proposalID, range: best.interval!, expiresAt: best.interval!.upperBound)
        for _ in 0..<50 where s.myHoldCellIDs.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(s.myHoldCellIDs, [best.id])
        runner.cancel()

        let empty = session(.noProposal)
        XCTAssertNil(empty.proposal)
        let emptyStore = try XCTUnwrap(empty.store as? InMemoryProposalStore)
        let created = try await emptyStore.create(NewProposal(title: "Dinner", window: DateRange(lower: HeatmapTests.date(2026, 11, 16, 0), upper: HeatmapTests.date(2026, 11, 23, 0)), expectedCount: 4))
        empty.adopt(created.id)
        XCTAssertEqual(empty.screen, .loading)
        await empty.load()
        XCTAssertEqual(empty.screen, .ready)
        XCTAssertEqual(empty.proposal?.title, "Dinner")
        XCTAssertEqual(empty.lockState, .inviteFriends(expected: 4))
        XCTAssertEqual(empty.weeks.count, 1)

        let gone = ProposalSession(store: emptyStore, proposalID: UUID(), calendar: cal, now: { [launch] in launch })
        await gone.load()
        XCTAssertEqual(gone.screen, .gone)
    }

    /// Value: protects=edit() applies the creator's title and count through the store, floors the count at those already joined, and maps the frozen-dates refusal (design 5.4A); fails_when=the floor is dropped, the saved plan is not applied, or the refusal is not mapped; why_new=only the store tests cover update(), not the session wrapper; seam=none; no_claim=the edit sheet UI (not driven here)
    func testEditAppliesTitleFloorsCountAndMapsFrozenDates() async throws {
        let s = session(.lockedInviteCreator)
        let p = try XCTUnwrap(s.proposal)
        XCTAssertTrue(s.hasAnyHold)
        var draft = ProposalDraft(editing: p)
        draft.title = "Dinner?"
        draft.expectedCount = 2
        draft.from = cal.date(byAdding: .day, value: 1, to: draft.from)!
        do { try await s.edit(draft); XCTFail("dates are frozen once friends marked times") } catch let e as UserFacingError {
            XCTAssertEqual(e.message, "Can't change the dates once friends have marked times.")
        }
        XCTAssertEqual(s.proposal?.title, p.title)
        let store = try XCTUnwrap(s.store as? InMemoryProposalStore)
        store.seed(users: store.users, proposals: store.proposals, slots: [], busyBlocks: store.busyBlocks, currentUserID: store.currentUserID)
        s.apply(try store.snapshot(of: p.id))
        XCTAssertFalse(s.hasAnyHold)
        draft = ProposalDraft(editing: s.proposal!)
        draft.title = "Dinner?"
        draft.expectedCount = 2
        try await s.edit(draft)
        XCTAssertEqual(s.proposal?.title, "Dinner")
        XCTAssertEqual(s.proposal?.expectedCount, p.joinedCount)
    }

    /// Value: protects=join() reloads after joining and maps a failed join to the invite sentence, load() maps a network failure to .error; fails_when=the error is rethrown raw or the screen stays loading; why_new=no test calls join(), and load()'s generic-failure branch is untested; seam=none; no_claim=the deep-link navigation (UI tests)
    func testJoinReloadsAndLoadFailureMapsToErrorScreen() async throws {
        let s = session(.lockedInvite)
        let store = try XCTUnwrap(s.store as? InMemoryProposalStore)
        try await s.join()
        XCTAssertEqual(s.screen, .ready)
        store.failNext[.join] = ProposalStoreError.network("offline")
        do { try await s.join(); XCTFail("join should fail") } catch let e as UserFacingError {
            XCTAssertEqual(e.message, "Couldn't open this invite.")
            XCTAssertEqual(e.details, "offline")
        }
        let fresh = ProposalSession(store: store, proposalID: FixtureData.proposalID, calendar: cal, now: { [launch] in launch })
        store.failNext[.load] = ProposalStoreError.network("offline")
        await fresh.load()
        XCTAssertEqual(fresh.screen, .error(UserFacingError(message: "Couldn't open this invite.", details: "offline")))
    }

    /// Value: protects=the invite message carries the plan's deep link and the DEMO flag follows the in-memory store; fails_when=inviteText drops the link or isDemo is wrong; why_new=ShareText.invite is tested in isolation, not the session wiring; seam=none; no_claim=the share sheet
    func testInviteTextCarriesDeepLinkAndDemoFlag() throws {
        let s = session(.lockedInviteCreator)
        let id = try XCTUnwrap(s.proposal?.id)
        XCTAssertTrue(try XCTUnwrap(s.inviteText).contains(DeepLink.proposal(id).url.absoluteString))
        XCTAssertTrue(s.isDemo)
        XCTAssertNil(session(.noProposal).inviteText)
    }
}
#endif
