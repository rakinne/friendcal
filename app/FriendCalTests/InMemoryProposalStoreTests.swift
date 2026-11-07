import XCTest
@testable import FriendCalCore

/// The loop contract every screen relies on (issue #5 D2, D3, D4, D9, D13, D15, C3, C5), against the
/// in-memory store that mirrors lock_proposal.sql / join_proposal.sql. Fixed New York calendar.
final class InMemoryProposalStoreTests: XCTestCase {
    private let sam = User(id: UUID(), displayName: "Sam")
    private let maya = User(id: UUID(), displayName: "Maya")
    private let leo = User(id: UUID(), displayName: "Leo")
    private let now = HeatmapTests.date(2026, 11, 8, 12)
    private func mon(_ h: Int, _ m: Int = 0) -> Date { HeatmapTests.date(2026, 11, 9, h, m) }
    private var window: DateRange { DateRange(lower: mon(0), upper: HeatmapTests.date(2026, 11, 23, 0)) }

    private func store(as user: User, recipients: [User]? = nil, expected: Int = 3, status: ProposalStatus = .requesting) -> (InMemoryProposalStore, Proposal) {
        let members = recipients ?? [sam, maya, leo]
        let p = Proposal(id: UUID(), title: "Brunch", window: window, createdBy: sam.id,
                         distribution: Distribution(mode: .newGroup, recipientIDs: members.map(\.id)), status: status, expectedCount: expected)
        let s = InMemoryProposalStore(users: [sam, maya, leo], proposals: [p], slots: [], currentUserID: user.id, now: { [now] in now })
        return (s, p)
    }

    private func code(_ error: Error) -> (String, String?)? {
        if case let ProposalStoreError.server(code, _, hint) = error { return (code, hint) }
        return nil
    }

    // MARK: create / join / list

    /// protects=create persists a requesting plan with the creator as its first recipient and the
    /// typed headcount (D4, D13), listed as Hosting; fails_when=the creator is missing from
    /// recipients, the headcount is adjusted, or the list omits it; no_claim=Supabase behavior.
    func testCreateMakesTheCreatorTheFirstRecipient() async throws {
        let s = InMemoryProposalStore(users: [sam], currentUserID: sam.id, now: { [now] in now })
        let p = try await s.create(NewProposal(title: "Brunch", window: window, expectedCount: 8))
        XCTAssertEqual(p.distribution.recipientIDs, [sam.id])
        XCTAssertEqual(p.status, .requesting)
        XCTAssertEqual(p.expectedCount, 8)
        XCTAssertEqual(p.createdAt, now)
        let list = try await s.proposals()
        XCTAssertEqual(list.map(\.id), [p.id])
        XCTAssertEqual(list.first?.isHosting, true)
        XCTAssertEqual(list.first?.joinedCount, 1)
    }

    /// protects=join appends once (idempotent), is allowed on a locked plan as a viewer (D13, delta
    /// O1) and refused on a cancelled one; fails_when=a second join duplicates the id, a locked plan
    /// refuses, the post-lock joiner is not recorded, or a cancelled plan accepts; no_claim=join_proposal SQL.
    func testJoinIsIdempotentAndAllowedAfterLock() async throws {
        let (s, p) = store(as: leo, recipients: [sam, maya])
        let joined = try await s.join(p.id)
        XCTAssertEqual(joined.distribution.recipientIDs, [sam.id, maya.id, leo.id])
        let again = try await s.join(p.id)
        XCTAssertEqual(again.distribution.recipientIDs.count, 3)
        XCTAssertTrue(joined.postLockRecipientIDs.isEmpty)

        let (locked, lp) = store(as: leo, recipients: [sam, maya], status: .locked)
        let late = try await locked.join(lp.id)
        XCTAssertEqual(late.postLockRecipientIDs, [leo.id])
        XCTAssertTrue(late.distribution.recipientIDs.contains(leo.id))

        let (cancelled, cp) = store(as: leo, recipients: [sam, maya], status: .cancelled)
        do { _ = try await cancelled.join(cp.id); XCTFail("joined a cancelled plan") } catch { XCTAssertEqual(code(error)?.0, "55000") }
        let list = try await s.proposals()
        XCTAssertEqual(list.first?.isHosting, false)
    }

    // MARK: holds

    /// protects=a tap writes this user's softHold with the given expiry (D9) and the stream reports
    /// it; a second tap elsewhere is independent; fails_when=the hold lands on another user, the
    /// expiry is dropped, or no snapshot is emitted; no_claim=Realtime delivery (in-memory stream).
    func testTapFreeWritesAHoldAndEmitsASnapshot() async throws {
        let (s, p) = store(as: maya)
        let stream = s.changes(for: p.id)
        let first = Task { await stream.first { _ in true } }
        await Task.yield()
        let range = DateRange(lower: mon(6), upper: mon(12))
        let slot = try await s.tapFree(proposalID: p.id, range: range, expiresAt: range.upperBound)
        XCTAssertEqual(slot.userID, maya.id)
        XCTAssertEqual(slot.state, .softHold)
        XCTAssertEqual(slot.expiresAt, mon(12))
        guard case .snapshot(let snap)? = await first.value else { return XCTFail("no snapshot") }
        XCTAssertEqual(snap.slots, [slot])
        XCTAssertEqual(snap.members.map(\.displayName), ["Sam", "Maya", "Leo"])
        let commitments = try await s.myCommitments()
        XCTAssertEqual(commitments, [slot])
    }

    /// protects=hold writes are refused for a non-member, on a locked plan, outside the window and
    /// when the user already holds that time elsewhere (D15, A2), each with the server's code and hint;
    /// fails_when=any guard is dropped or a refusal writes a row; no_claim=the RLS policies (PR2 sql lane).
    func testTapFreeRefusals() async throws {
        let stranger = User(id: UUID(), displayName: "Stranger")
        let (s1, p1) = store(as: stranger)
        await assertRefused(try await s1.tapFree(proposalID: p1.id, range: DateRange(lower: mon(6), upper: mon(12)), expiresAt: nil), code: "42501", hint: "FC_NOT_MEMBER")
        let (s2, p2) = store(as: maya, status: .locked)
        await assertRefused(try await s2.tapFree(proposalID: p2.id, range: DateRange(lower: mon(6), upper: mon(12)), expiresAt: nil), code: "55000", hint: "FC_LOCKED")
        let (s3, p3) = store(as: maya)
        await assertRefused(try await s3.tapFree(proposalID: p3.id, range: DateRange(lower: HeatmapTests.date(2026, 11, 8, 6), upper: mon(12)), expiresAt: nil), code: "22023", hint: "FC_WINDOW")
        let (s4, p4) = store(as: maya)
        s4.busyBlocks = [BusyBlock(userID: maya.id, range: DateRange(lower: mon(9), upper: mon(10)))]
        do {
            _ = try await s4.tapFree(proposalID: p4.id, range: DateRange(lower: mon(6), upper: mon(12)), expiresAt: nil)
            XCTFail("held over a Busy block")
        } catch {
            XCTAssertEqual(error as? ProposalStoreError, .heldElsewhere)
        }
        XCTAssertTrue(s1.slots.isEmpty && s2.slots.isEmpty && s3.slots.isEmpty && s4.slots.isEmpty)
    }

    /// protects=release removes only the caller's own hold (C3); fails_when=another user's hold can
    /// be released or the owner's cannot; no_claim=the delete-own policy (PR2).
    func testReleaseIsOwnOnly() async throws {
        let (s, p) = store(as: maya)
        let mine = try await s.tapFree(proposalID: p.id, range: DateRange(lower: mon(6), upper: mon(12)), expiresAt: nil)
        let (other, _) = (InMemoryProposalStore(users: [sam, maya], proposals: [p], slots: [mine], currentUserID: sam.id), ())
        do { try await other.release(slotID: mine.id); XCTFail("released another user's hold") } catch { XCTAssertEqual(code(error)?.0, "42501") }
        XCTAssertEqual(other.slots.count, 1)
        try await s.release(slotID: mine.id)
        XCTAssertTrue(s.slots.isEmpty)
        do { try await s.release(slotID: mine.id); XCTFail("released twice") } catch { XCTAssertEqual(error as? ProposalStoreError, .notFound(mine.id)) }
    }

    // MARK: lock

    private func hold(_ s: InMemoryProposalStore, _ user: User, _ p: Proposal, _ from: Date, _ to: Date) {
        s.seed(users: s.users, proposals: s.proposals,
               slots: s.slots + [AvailabilitySlot(userID: user.id, range: DateRange(lower: from, upper: to), sourceProposalID: p.id, state: .softHold, expiresAt: to)],
               busyBlocks: s.busyBlocks, currentUserID: s.currentUserID)
    }

    /// protects=a lock at quorum sets status, both ends, lockedAt and the attendees from the
    /// promotion (C1), writes one Busy block per attendee and clears every hold of the plan;
    /// fails_when=attendees are missing, holds survive, or the window differs; no_claim=lock_proposal SQL.
    func testLockAtQuorumSettlesThePlan() async throws {
        let (s, p) = store(as: sam)
        for u in [sam, maya, leo] { hold(s, u, p, mon(9), mon(12)) }
        let window = DateRange(lower: mon(9), upper: mon(11))
        let locked = try await s.lock(p.id, window: window)
        XCTAssertEqual(locked.status, .locked)
        XCTAssertEqual(locked.lockedWindow, window)
        XCTAssertEqual(locked.lockedAt, now)
        XCTAssertEqual(Set(locked.lockedAttendeeIDs), [sam.id, maya.id, leo.id])
        XCTAssertTrue(s.slots.isEmpty)
        XCTAssertEqual(s.busyBlocks.count, 3)
        XCTAssertTrue(s.busyBlocks.allSatisfy { $0.range == window })
        let reloaded = try await s.load(p.id)
        XCTAssertEqual(reloaded.proposal, locked)
    }

    /// protects=a refusal leaves the plan requesting with its holds intact (C5, "lock server-first");
    /// quorum uses max(expected, joined) (D13); fails_when=the store mutates before refusing or the
    /// denominator ignores expected; no_claim=none beyond protects.
    func testLockRefusalLeavesStatusRequesting() async throws {
        let (s, p) = store(as: sam, expected: 10) // 3 of 10 free is under 80%
        for u in [sam, maya, leo] { hold(s, u, p, mon(9), mon(12)) }
        await assertRefused(try await s.lock(p.id, window: DateRange(lower: mon(9), upper: mon(11))), code: "22023", hint: "FC_QUORUM")
        XCTAssertEqual(s.proposals.first?.status, .requesting)
        XCTAssertEqual(s.slots.count, 3)
        XCTAssertTrue(s.busyBlocks.isEmpty)
        XCTAssertNil(s.proposals.first?.lockedDate)
    }

    /// protects=the creator-only, requesting-only, >= 60-min-inside-the-window and >= 2-recipient rules
    /// (D13, D14, D15) with the server's codes and hints; fails_when=any rule is skipped or the
    /// hint/code pair changes; no_claim=the SQL raises (lock_proposal_test.sql).
    func testLockGuards() async throws {
        let (notCreator, p1) = store(as: maya)
        await assertRefused(try await notCreator.lock(p1.id, window: DateRange(lower: mon(9), upper: mon(11))), code: "42501", hint: "FC_NOT_CREATOR")
        let (already, p2) = store(as: sam, status: .locked)
        await assertRefused(try await already.lock(p2.id, window: DateRange(lower: mon(9), upper: mon(11))), code: "55000", hint: "FC_LOCKED")
        let (short, p3) = store(as: sam)
        await assertRefused(try await short.lock(p3.id, window: DateRange(lower: mon(9), upper: mon(9, 45))), code: "22023", hint: "FC_WINDOW")
        await assertRefused(try await short.lock(p3.id, window: DateRange(lower: HeatmapTests.date(2026, 11, 8, 9), upper: mon(11))), code: "22023", hint: "FC_WINDOW")
        let (alone, p4) = store(as: sam, recipients: [sam])
        hold(alone, sam, p4, mon(9), mon(12))
        await assertRefused(try await alone.lock(p4.id, window: DateRange(lower: mon(9), upper: mon(11))), code: "22023", hint: "FC_NO_RECIPIENTS")
        do { _ = try await alone.lock(UUID(), window: DateRange(lower: mon(9), upper: mon(11))); XCTFail("locked a missing plan") } catch {
            guard case ProposalStoreError.notFound = error else { return XCTFail("\(error)") }
        }
    }

    /// protects=a recipient with a Busy block over the window neither counts nor blocks the lock
    /// (lock_proposal.sql rule, mirrored); fails_when=they are promoted (a second Busy block) or their
    /// absence is not counted against quorum; no_claim=the exclusion constraint.
    func testBusyRecipientDoesNotCountOrBlock() async throws {
        let (s, p) = store(as: sam, expected: 3)
        for u in [sam, maya, leo] { hold(s, u, p, mon(9), mon(12)) }
        s.busyBlocks = [BusyBlock(userID: leo.id, range: DateRange(lower: mon(10), upper: mon(10, 30)))]
        await assertRefused(try await s.lock(p.id, window: DateRange(lower: mon(9), upper: mon(11))), code: "22023", hint: "FC_QUORUM")
        let (five, p5) = store(as: sam, recipients: [sam, maya, leo, User(id: UUID(), displayName: "D"), User(id: UUID(), displayName: "E")], expected: 5)
        for id in p5.distribution.recipientIDs { hold(five, User(id: id, displayName: ""), p5, mon(9), mon(12)) }
        five.busyBlocks = [BusyBlock(userID: leo.id, range: DateRange(lower: mon(10), upper: mon(10, 30)))]
        let locked = try await five.lock(p5.id, window: DateRange(lower: mon(9), upper: mon(11)))
        XCTAssertEqual(locked.lockedAttendeeIDs.count, 4)
        XCTAssertFalse(locked.lockedAttendeeIDs.contains(leo.id))
    }

    // MARK: edit

    /// protects=the creator edits title and headcount while requesting; the window is frozen once a
    /// hold exists and nothing is editable once locked (design 5.4A, delta A1/O2); fails_when=a
    /// recipient can edit, a window change with holds succeeds, or a locked plan accepts an edit;
    /// no_claim=the proposals_edit_guard trigger (PR2).
    func testUpdateRules() async throws {
        let (s, p) = store(as: sam)
        var edited = p
        edited.title = "Dinner"
        edited.expectedCount = 6
        let saved = try await s.update(edited)
        XCTAssertEqual(saved.title, "Dinner")
        XCTAssertEqual(saved.expectedCount, 6)
        edited.window = DateRange(lower: mon(0), upper: HeatmapTests.date(2026, 11, 30, 0))
        let moved = try await s.update(edited)
        XCTAssertEqual(moved.window, edited.window, "dates move while nobody has marked")
        hold(s, maya, p, mon(9), mon(12))
        edited.window = DateRange(lower: mon(0), upper: HeatmapTests.date(2026, 12, 7, 0))
        await assertRefused(try await s.update(edited), code: "22023", hint: "FC_DATES_FROZEN")
        edited.window = s.proposals[0].window
        edited.title = "Lunch"
        let retitled = try await s.update(edited)
        XCTAssertEqual(retitled.title, "Lunch", "title still edits with holds")
        let (recipient, rp) = store(as: maya)
        await assertRefused(try await recipient.update(rp), code: "42501", hint: "FC_NOT_CREATOR")
        let (locked, lp) = store(as: sam, status: .locked)
        await assertRefused(try await locked.update(lp), code: "55000", hint: "FC_LOCKED")
    }

    // MARK: changes / failures

    /// protects=the stream finishes when its task is cancelled and a removed plan ends it, so a
    /// closed screen leaks nothing; fails_when=a cancelled stream keeps a continuation or a removed
    /// plan keeps emitting; no_claim=Realtime channel teardown (PR2).
    func testChangesFinishOnCancelAndRemoval() async throws {
        let (s, p) = store(as: maya)
        let collected = Task { () -> Int in
            var n = 0
            for await _ in s.changes(for: p.id) { n += 1 }
            return n
        }
        await Task.yield()
        _ = try await s.tapFree(proposalID: p.id, range: DateRange(lower: mon(6), upper: mon(12)), expiresAt: nil)
        s.remove(proposalID: p.id)
        let events = await collected.value
        XCTAssertEqual(events, 1)
        do { _ = try await s.load(p.id); XCTFail("loaded a removed plan") } catch { XCTAssertEqual(error as? ProposalStoreError, .notFound(p.id)) }

        let cancelled = Task { for await _ in s.changes(for: p.id) {} }
        await Task.yield()
        cancelled.cancel()
        await cancelled.value
    }

    /// protects=failNext throws exactly once and the next call succeeds, so revert-and-retry paths can
    /// be driven without a network (design 2.3A); fails_when=the failure sticks or never fires;
    /// no_claim=none beyond protects.
    func testFailNextThrowsOnce() async throws {
        let (s, p) = store(as: maya)
        s.failNext[.tapFree] = ProposalStoreError.network("offline")
        do { _ = try await s.tapFree(proposalID: p.id, range: DateRange(lower: mon(6), upper: mon(12)), expiresAt: nil); XCTFail("did not throw") } catch {
            XCTAssertEqual(error as? ProposalStoreError, .network("offline"))
        }
        XCTAssertTrue(s.slots.isEmpty)
        _ = try await s.tapFree(proposalID: p.id, range: DateRange(lower: mon(6), upper: mon(12)), expiresAt: nil)
        XCTAssertEqual(s.slots.count, 1)
    }

    private func assertRefused<T>(_ body: @autoclosure () async throws -> T, code expected: String, hint: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected) \(hint)", file: file, line: line)
        } catch {
            XCTAssertEqual(code(error)?.0, expected, "\(error)", file: file, line: line)
            XCTAssertEqual(code(error)?.1, hint, "\(error)", file: file, line: line)
        }
    }
}
