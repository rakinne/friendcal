import XCTest
@testable import FriendCalCore

/// The auth state machine, the identity generation, and account deletion through the seam.
///
/// The identity tests here are the reason this file exists. The bug they protect against needs two
/// identities and bad timing to reproduce — an action begun by one person, suspended, and resumed
/// after somebody else signed in — so it survives any amount of single-user tapping. A double-tap
/// test does not come near it: both taps are the same person.
@MainActor
final class AuthStateTests: XCTestCase {
    private let sam = User(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayName: "Sam")
    private let maya = User(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, displayName: "Maya")

    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 12; c.day = day; c.hour = hour
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private func plan(_ id: String, creator: UUID, recipients: [UUID],
                      status: ProposalStatus = .requesting) -> Proposal {
        Proposal(id: UUID(uuidString: id)!, title: "Plan",
                 window: DateRange(lower: date(1), upper: date(28)),
                 createdBy: creator,
                 distribution: Distribution(mode: .newGroup, recipientIDs: recipients),
                 status: status)
    }

    // MARK: - The state machine

    /// protects=the states a sign-in passes through and the generation moving exactly once;
    /// fails_when=the store leaves `.signingIn` showing after success, or bumps the generation on a
    /// presentation-only change; no_claim=Apple's callback timing, which has no stand-in here.
    func testSignInWalksTheStates() async throws {
        let store = InMemoryProposalStore()
        XCTAssertEqual(store.authState, .signedOut)
        XCTAssertEqual(store.identityGeneration, 0)

        let id = try await store.signIn(displayName: "Maya")
        XCTAssertEqual(store.authState, .signedIn(id))
        XCTAssertEqual(store.identityGeneration, 1, "one identity change, one bump")

        // Signing in again while already signed in is a no-op, not a second identity.
        let again = try await store.signIn(displayName: "Maya")
        XCTAssertEqual(again, id)
        XCTAssertEqual(store.identityGeneration, 1)
    }

    /// protects=a refused sign-in landing on `.failed` with the mapped sentence, so the gate can say
    /// what happened; fails_when=a failure falls through to `.signedOut`, which looks identical to
    /// never having tried and silently loses the reason.
    func testRefusedSignInLandsOnFailedWithItsReason() async {
        let store = InMemoryProposalStore()
        store.failNext[.signIn] = ProposalStoreError.network("offline")
        do {
            _ = try await store.signIn(displayName: "Maya")
            XCTFail("expected a refusal")
        } catch {
            guard case .failed(let shown) = store.authState else {
                return XCTFail("expected .failed, got \(store.authState)")
            }
            XCTAssertEqual(shown.message, "Couldn't sign you in. Try again.")
            XCTAssertNotNil(shown.details, "the raw cause is kept for the Details line")
        }
        XCTAssertEqual(store.identityGeneration, 0, "a failed attempt is not an identity change")
        XCTAssertNil(store.currentUserID)
    }

    /// protects=sign-out always succeeding and ending signedOut, and bumping the generation;
    /// fails_when=sign-out is modelled as fallible, which gives the UI a state it cannot resolve.
    func testSignOutAlwaysLands() async throws {
        let store = InMemoryProposalStore()
        let id = try await store.signIn(displayName: "Maya")
        await store.signOut()
        XCTAssertEqual(store.authState, .signedOut)
        XCTAssertNil(store.currentUserID)
        XCTAssertEqual(store.identityGeneration, 2)
        XCTAssertNotNil(id)
    }

    /// protects=the observable projection: a subscriber gets the current state immediately and then
    /// every change, so a screen never renders from a stale read; fails_when=the stream only yields
    /// future changes and the first render shows signedOut for a signed-in store.
    func testAuthChangesReplaysCurrentStateThenFollows() async throws {
        let store = InMemoryProposalStore(users: [maya], currentUserID: maya.id)
        var iterator = store.authChanges.makeAsyncIterator()

        let first = await iterator.next()
        XCTAssertEqual(first, .signedIn(maya.id), "the current state arrives without waiting for a change")

        await store.signOut()
        let next = await iterator.next()
        XCTAssertEqual(next, .signedOut)
    }

    // MARK: - Identity generation across awaits

    /// protects=THE F6 BUG: an operation begun as A and resumed after a sign-out and sign-in as B
    /// fails instead of writing as B; fails_when=the identity is read after the await rather than
    /// captured before it; no_claim=real network timing, which the injected latency stands in for.
    func testOperationStartedAsOneIdentityDoesNotResumeAsAnother() async throws {
        let p = plan("10000000-0000-0000-0000-000000000001", creator: sam.id, recipients: [sam.id, maya.id])
        let store = InMemoryProposalStore(users: [sam, maya], proposals: [p],
                                          currentUserID: maya.id, now: { self.date(5) })
        store.latency = .milliseconds(120)

        // Maya taps a free slot. The call suspends inside the gate.
        let mayasTap = Task {
            try await store.tapFree(proposalID: p.id,
                                    range: DateRange(lower: self.date(5, 18), upper: self.date(5, 20)),
                                    expiresAt: nil)
        }
        // Meanwhile she signs out and Sam signs in.
        try await Task.sleep(for: .milliseconds(20))
        await store.signOut()
        _ = try await store.signIn(displayName: "Sam")

        do {
            _ = try await mayasTap.value
            XCTFail("Maya's tap must not complete after Sam signed in")
        } catch {
            XCTAssertEqual(error as? ProposalStoreError, .identityChanged)
        }
        XCTAssertTrue(store.slots.isEmpty, "and nothing was written for either identity")
    }

    /// protects=the same guard when the SAME person signs back in -- the generation moved even though
    /// the id matches, and work begun in the previous session still must not land; fails_when=the
    /// check compares only the user id, which is the obvious implementation and is not enough.
    func testWorkFromAPreviousSessionDoesNotLandAfterSigningBackIn() async throws {
        let p = plan("10000000-0000-0000-0000-000000000002", creator: maya.id, recipients: [maya.id])
        let store = InMemoryProposalStore(users: [maya], proposals: [p],
                                          currentUserID: maya.id, now: { self.date(5) })
        store.latency = .milliseconds(120)

        let inFlight = Task { try await store.myCommitments(from: self.date(1)) }
        try await Task.sleep(for: .milliseconds(20))
        await store.signOut()
        // The in-memory store mints a fresh id on sign-in, so pin the id back to Maya's to isolate
        // the generation check from the id check.
        store.seed(users: [maya], proposals: [p], slots: [], busyBlocks: [], currentUserID: maya.id)

        do {
            _ = try await inFlight.value
            XCTFail("work from the previous session must not complete")
        } catch {
            XCTAssertEqual(error as? ProposalStoreError, .identityChanged,
                           "the generation moved even though the id came back the same")
        }
    }

    /// protects=the guard NOT firing in the ordinary case, so it cannot be implemented as "always
    /// fail"; fails_when=the generation is bumped by something that is not an identity change.
    func testOrdinaryOperationsAreUnaffected() async throws {
        let p = plan("10000000-0000-0000-0000-000000000003", creator: maya.id, recipients: [maya.id])
        let store = InMemoryProposalStore(users: [maya], proposals: [p],
                                          currentUserID: maya.id, now: { self.date(5) })
        store.latency = .milliseconds(30)
        let slot = try await store.tapFree(proposalID: p.id,
                                           range: DateRange(lower: date(5, 18), upper: date(5, 20)),
                                           expiresAt: nil)
        XCTAssertEqual(slot.userID, maya.id)
        let commitments = try await store.myCommitments(from: date(1))
        XCTAssertEqual(commitments.count, 1)
    }

    // MARK: - Deletion

    /// protects=deletion cancelling the caller's open plans, releasing EVERY hold on them including
    /// other people's, leaving locked plans standing, and ending signed out; fails_when=cancellation
    /// releases only the departing user's holds (F8), or a locked plan is torn down with them.
    func testDeletionCancelsReleasesAndKeepsLockedPlans() async throws {
        let open = plan("20000000-0000-0000-0000-000000000001", creator: maya.id, recipients: [maya.id, sam.id])
        let locked = plan("20000000-0000-0000-0000-000000000002", creator: maya.id,
                          recipients: [maya.id, sam.id], status: .locked)
        let othersPlan = plan("20000000-0000-0000-0000-000000000003", creator: sam.id, recipients: [sam.id, maya.id])

        let store = InMemoryProposalStore(
            users: [maya, sam], proposals: [open, locked, othersPlan],
            slots: [
                AvailabilitySlot(userID: maya.id, range: DateRange(lower: date(5, 18), upper: date(5, 20)),
                                 sourceProposalID: open.id, state: .softHold, expiresAt: date(20)),
                // Sam's hold on Maya's plan, with NO expiry: the one that would block Sam forever.
                AvailabilitySlot(userID: sam.id, range: DateRange(lower: date(5, 18), upper: date(5, 20)),
                                 sourceProposalID: open.id, state: .softHold, expiresAt: nil),
                // Maya's hold on Sam's plan.
                AvailabilitySlot(userID: maya.id, range: DateRange(lower: date(9, 18), upper: date(9, 20)),
                                 sourceProposalID: othersPlan.id, state: .softHold, expiresAt: date(20)),
                // A non-softHold row, which must survive.
                AvailabilitySlot(userID: maya.id, range: DateRange(lower: date(7, 9), upper: date(7, 10)),
                                 sourceProposalID: open.id, state: .free),
            ],
            busyBlocks: [BusyBlock(userID: maya.id, range: DateRange(lower: date(14, 18), upper: date(14, 20)),
                                   sourceProposalID: locked.id)],
            currentUserID: maya.id, now: { self.date(3) }
        )

        let receipt = try await store.deleteAccount()
        XCTAssertFalse(receipt.alreadyDeleted)
        XCTAssertEqual(receipt.cancelledPlans, 1)
        XCTAssertEqual(receipt.releasedHolds, 3, "Maya's two plus Sam's one on the cancelled plan")
        XCTAssertEqual(receipt.lockedPlansKept, 1)

        XCTAssertEqual(store.proposals.first { $0.id == open.id }?.status, .cancelled)
        XCTAssertEqual(store.proposals.first { $0.id == locked.id }?.status, .locked)
        XCTAssertEqual(store.proposals.first { $0.id == othersPlan.id }?.status, .requesting,
                       "someone else's plan is untouched")
        XCTAssertFalse(store.slots.contains { $0.userID == sam.id && $0.state == .softHold },
                       "Sam's null-expiry hold on the cancelled plan is released")
        XCTAssertTrue(store.slots.contains { $0.state == .free }, "the free row survives")
        XCTAssertEqual(store.busyBlocks.count, 1, "the locked plan's Busy block stands")

        // The tombstone, and the signed-out landing.
        XCTAssertEqual(store.users.first { $0.id == maya.id }?.displayName, "Deleted account")
        XCTAssertEqual(store.authState, .signedOut)
        XCTAssertNil(store.currentUserID)
    }

    /// protects=C3, a resumed deletion converging: the app can die between sending the call and
    /// seeing the result, so a second attempt must succeed and say it was already done;
    /// fails_when=the second call refuses, leaving the client to guess whether a refusal means
    /// failure or completion.
    func testResumedDeletionConverges() async throws {
        let locked = plan("20000000-0000-0000-0000-000000000004", creator: maya.id,
                          recipients: [maya.id], status: .locked)
        let store = InMemoryProposalStore(users: [maya], proposals: [locked],
                                          currentUserID: maya.id, now: { self.date(3) })
        let first = try await store.deleteAccount()
        XCTAssertFalse(first.alreadyDeleted)

        // The app relaunches, restores the identity, and retries because it never saw the result.
        store.seed(users: store.users, proposals: store.proposals, slots: store.slots,
                   busyBlocks: store.busyBlocks, currentUserID: maya.id)
        let second = try await store.deleteAccount()
        XCTAssertTrue(second.alreadyDeleted)
        XCTAssertEqual(second.lockedPlansKept, 1, "and it still reports the state accurately")
        XCTAssertEqual(second.cancelledPlans, 0, "without cancelling anything a second time")
        XCTAssertEqual(store.authState, .signedOut)
        XCTAssertEqual(store.users.first { $0.id == maya.id }?.displayName, "Deleted account",
                       "the tombstone is not re-stamped")
    }

    /// protects=deletion needing an identity at all; fails_when=a signed-out caller gets something
    /// other than notSignedIn.
    func testDeletionRequiresAnIdentity() async {
        let store = InMemoryProposalStore()
        do {
            _ = try await store.deleteAccount()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? ProposalStoreError, .notSignedIn)
        }
    }
}
