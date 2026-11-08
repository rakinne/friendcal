import XCTest
@testable import FriendCalCore

/// The store's half of the commitments contract: provenance survives, titles are authorized, and the
/// seam is gated like every other operation.
///
/// This is the Swift mirror of supabase/tests/commitments_test.sql. The in-memory store is the only
/// store this wave ships, so if it is more permissive than the server, every screen gets built and
/// reviewed against a world that does not exist. The title assertions below are the ones that matter:
/// they are the same claim `my_commitments()` re-applies its read predicate for.
@MainActor
final class CommitmentStoreTests: XCTestCase {
    private let host = User(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayName: "Sam")
    private let me = User(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, displayName: "Maya")
    private let other = User(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, displayName: "Leo")

    private func date(_ day: Int, _ hour: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 12; c.day = day; c.hour = hour
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private func plan(
        _ id: String,
        title: String,
        recipients: [UUID],
        hiddenFrom: [UUID] = [],
        status: ProposalStatus = .locked
    ) -> Proposal {
        Proposal(
            id: UUID(uuidString: id)!,
            title: title,
            window: DateRange(lower: date(1, 0), upper: date(28, 0)),
            createdBy: host.id,
            distribution: Distribution(mode: .newGroup, recipientIDs: recipients),
            status: status,
            hiddenFrom: hiddenFrom
        )
    }

    /// protects=a Busy block from a plan the viewer may read comes back named and attributed;
    /// fails_when=provenance is dropped on the way out of the store, which is what used to happen;
    /// no_claim=what the network store returns, which commitments_test.sql covers.
    func testLockedBlockCarriesProvenanceAndTitle() async throws {
        let mine = plan("10000000-0000-0000-0000-000000000001", title: "Dinner", recipients: [host.id, me.id])
        let store = InMemoryProposalStore(
            users: [host, me], proposals: [mine], slots: [],
            busyBlocks: [BusyBlock(userID: me.id,
                                   range: DateRange(lower: date(5, 18), upper: date(5, 20)),
                                   sourceProposalID: mine.id)],
            currentUserID: me.id, now: { self.date(1, 0) }
        )

        let got = try await store.myCommitments(from: date(1, 0))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].kind, .locked)
        XCTAssertEqual(got[0].sourceProposalID, mine.id)
        XCTAssertEqual(got[0].planTitle, mine.displayTitle)
    }

    /// protects=THE ORACLE CASE: a block from a plan the viewer is excluded from still appears, and
    /// stays nameless; fails_when=the store hands back the title because it technically has the row
    /// in memory -- the in-memory equivalent of a definer function skipping its read predicate;
    /// no_claim=that the server behaves this way, which is asserted in SQL.
    func testBlockFromAnExcludedPlanAppearsWithoutItsName() async throws {
        // A surprise for Maya. She is listed as a recipient AND excluded, so her calendar is
        // genuinely blocked and she must see that -- she must not see what it is for.
        let surprise = plan("10000000-0000-0000-0000-000000000002",
                            title: "Surprise for Maya",
                            recipients: [host.id, me.id, other.id],
                            hiddenFrom: [me.id])
        let store = InMemoryProposalStore(
            users: [host, me, other], proposals: [surprise], slots: [],
            busyBlocks: [
                BusyBlock(userID: me.id, range: DateRange(lower: date(20, 19), upper: date(20, 22)),
                          visibility: .stealth, hiddenFrom: [me.id], sourceProposalID: surprise.id),
                BusyBlock(userID: other.id, range: DateRange(lower: date(20, 19), upper: date(20, 22)),
                          visibility: .stealth, hiddenFrom: [me.id], sourceProposalID: surprise.id),
            ],
            currentUserID: me.id, now: { self.date(1, 0) }
        )

        let got = try await store.myCommitments(from: date(1, 0))
        XCTAssertEqual(got.count, 1, "only her own block; not everyone else's")
        XCTAssertEqual(got[0].kind, .locked)
        XCTAssertNotNil(got[0].sourceProposalID, "there IS a plan behind it")
        XCTAssertNil(got[0].planTitle, "and she may not name it")
        XCTAssertEqual(got[0].range, DateRange(lower: date(20, 19), upper: date(20, 22)),
                       "the time is honest, which is the point of showing the row at all")

        // And exclusion outranks membership: she cannot read the plan either.
        XCTAssertFalse(surprise.isReadable(by: me.id))
        XCTAssertTrue(surprise.isRecipient(me.id), "even though she is listed as a recipient")
    }

    /// protects=the host of that same surprise seeing its name, so the withholding is per-viewer and
    /// not a blanket nil; fails_when=titles are dropped for everyone, which would hide the feature
    /// rather than protect it.
    func testTheHostOfTheSurpriseSeesItsName() async throws {
        let surprise = plan("10000000-0000-0000-0000-000000000002",
                            title: "Surprise for Maya",
                            recipients: [host.id, me.id, other.id],
                            hiddenFrom: [me.id])
        let store = InMemoryProposalStore(
            users: [host, me, other], proposals: [surprise], slots: [],
            busyBlocks: [BusyBlock(userID: host.id,
                                   range: DateRange(lower: date(20, 19), upper: date(20, 22)),
                                   visibility: .stealth, hiddenFrom: [me.id], sourceProposalID: surprise.id)],
            currentUserID: host.id, now: { self.date(1, 0) }
        )
        let got = try await store.myCommitments(from: date(1, 0))
        XCTAssertEqual(got.first?.planTitle, surprise.displayTitle)
    }

    /// protects=a plan the viewer is simply not party to being nameless for a different reason than
    /// exclusion; fails_when=readability checks only hiddenFrom and forgets membership.
    func testBlockFromAPlanTheViewerIsNotPartyToIsNameless() async throws {
        let strangers = plan("10000000-0000-0000-0000-000000000003", title: "Not yours",
                             recipients: [host.id, other.id])
        let store = InMemoryProposalStore(
            users: [host, me, other], proposals: [strangers], slots: [],
            busyBlocks: [BusyBlock(userID: me.id,
                                   range: DateRange(lower: date(26, 10), upper: date(26, 12)),
                                   sourceProposalID: strangers.id)],
            currentUserID: me.id, now: { self.date(1, 0) }
        )
        let got = try await store.myCommitments(from: date(1, 0))
        XCTAssertNil(got.first?.planTitle)
        XCTAssertNotNil(got.first?.sourceProposalID)
    }

    /// protects=the three kinds and what is excluded: self-made blocks are `busy`, holds are `held`,
    /// expired holds and `.free` rows are not commitments at all; fails_when=state filtering is lost
    /// and the screen shows free time as a commitment.
    func testKindsAndExclusions() async throws {
        let open = plan("10000000-0000-0000-0000-000000000004", title: "Maybe",
                        recipients: [host.id, me.id], status: .requesting)
        let store = InMemoryProposalStore(
            users: [host, me], proposals: [open],
            slots: [
                AvailabilitySlot(userID: me.id, range: DateRange(lower: date(5, 18), upper: date(5, 20)),
                                 sourceProposalID: open.id, state: .softHold, expiresAt: date(10, 0)),
                // Lapsed: still points at future time, so only the expiry filter catches it.
                AvailabilitySlot(userID: me.id, range: DateRange(lower: date(6, 18), upper: date(6, 20)),
                                 sourceProposalID: open.id, state: .softHold, expiresAt: date(2, 0)),
                // Free time is not a commitment.
                AvailabilitySlot(userID: me.id, range: DateRange(lower: date(7, 9), upper: date(7, 10)),
                                 sourceProposalID: open.id, state: .free),
            ],
            busyBlocks: [BusyBlock(userID: me.id, range: DateRange(lower: date(8, 9), upper: date(8, 10)))],
            currentUserID: me.id, now: { self.date(3, 0) }
        )

        let got = try await store.myCommitments(from: date(1, 0))
        XCTAssertEqual(got.map(\.kind), [.held, .busy], "in time order: the hold on the 5th, then the block on the 8th")
        XCTAssertNil(got[1].sourceProposalID, "a self-made block has no plan")
        XCTAssertNil(got[1].planTitle)
    }

    /// protects=the overlap horizon through the real seam, not just the value type; fails_when=the
    /// store filters on start instead of overlap and drops something still running.
    func testHorizonIsOverlapBasedThroughTheStore() async throws {
        let store = InMemoryProposalStore(
            users: [me], proposals: [], slots: [],
            busyBlocks: [BusyBlock(userID: me.id, range: DateRange(lower: date(19, 22), upper: date(20, 6)))],
            currentUserID: me.id, now: { self.date(20, 0) }
        )
        // Awaited into locals: XCTAssert* takes an autoclosure, which cannot be async.
        let atMidnight = try await store.myCommitments(from: date(20, 0))
        XCTAssertEqual(atMidnight.count, 1, "it began on the 19th and is still running at midnight on the 20th")
        let atSix = try await store.myCommitments(from: date(20, 6))
        XCTAssertEqual(atSix.count, 0, "and is over at exactly 06:00")
    }

    /// protects=the seam being gated like every other operation, so the error map and loading states
    /// are reachable for this screen too; fails_when=myCommitments bypasses `gate`, which it used to.
    func testSeamIsGatedAndRefusesWhenSignedOut() async throws {
        let store = InMemoryProposalStore(users: [me], currentUserID: me.id, now: { self.date(1, 0) })
        store.failNext[.myCommitments] = ProposalStoreError.network("offline")
        do {
            _ = try await store.myCommitments(from: date(1, 0))
            XCTFail("the gate did not fire")
        } catch {
            XCTAssertEqual(error as? ProposalStoreError, .network("offline"))
        }
        // And it is consumed, so the next call succeeds.
        let afterward = try await store.myCommitments(from: date(1, 0))
        XCTAssertTrue(afterward.isEmpty, "failNext is one-shot; the second call runs normally")

        let signedOut = InMemoryProposalStore(users: [], currentUserID: nil, now: { self.date(1, 0) })
        do {
            _ = try await signedOut.myCommitments(from: date(1, 0))
            XCTFail("a signed-out caller must be refused")
        } catch {
            XCTAssertEqual(error as? ProposalStoreError, .notSignedIn)
        }
    }

    /// protects=`gate` propagating cancellation instead of swallowing it, so an operation whose task
    /// was cancelled stops rather than committing its write (outside voice F6); fails_when=the sleep
    /// is `try?` again, which discards CancellationError.
    func testCancellationPropagatesOutOfTheGate() async throws {
        let store = InMemoryProposalStore(users: [me], currentUserID: me.id, now: { self.date(1, 0) })
        store.latency = .milliseconds(200)

        let task = Task { try await store.myCommitments(from: self.date(1, 0)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled operation must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
