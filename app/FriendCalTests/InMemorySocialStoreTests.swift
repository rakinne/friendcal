import XCTest
@testable import FriendCalCore

/// Poke and Tag along against the in-memory store, which mirrors supabase/social.sql refusal for
/// refusal (the same SQLSTATE and FC_* hint). `social_test.sql` asserts the same cases on Postgres;
/// when one side changes, the matching case on the other must too.
@MainActor
final class InMemorySocialStoreTests: XCTestCase {
    private let sam = User(id: UUID(), displayName: "Sam")
    private let maya = User(id: UUID(), displayName: "Maya")
    private let leo = User(id: UUID(), displayName: "Leo")
    private let jalen = User(id: UUID(), displayName: "Jalen")
    private let arlo = User(id: UUID(), displayName: "Arlo")
    private let cleo = User(id: UUID(), displayName: "Cleo")
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var store: InMemoryProposalStore!
    private var open: Proposal!, surprise: Proposal!, locked: Proposal!, over: Proposal!

    override func setUp() async throws {
        let now = clock
        let window = DateRange(lower: now.addingTimeInterval(-86_400), upper: now.addingTimeInterval(14 * 86_400))
        func plan(_ title: String, _ recipients: [User], hidden: [User] = []) -> Proposal {
            Proposal(id: UUID(), title: title, window: window, createdBy: sam.id,
                     distribution: Distribution(mode: .newGroup, recipientIDs: recipients.map(\.id)), hiddenFrom: hidden.map(\.id))
        }
        open = plan("Brunch", [sam, maya, leo, jalen])
        surprise = plan("Surprise for Jalen", [sam, maya, jalen], hidden: [jalen])
        locked = plan("Tacos", [sam, maya, cleo])
        ProposalService.apply(window: DateRange(lower: now.addingTimeInterval(2 * 86_400), upper: now.addingTimeInterval(2 * 86_400 + 7200)),
                              to: &locked, attendees: [sam.id, maya.id], at: now)
        over = plan("Last week", [sam, cleo])
        ProposalService.apply(window: DateRange(lower: now.addingTimeInterval(-3 * 86_400), upper: now.addingTimeInterval(-3 * 86_400 + 7200)),
                              to: &over, attendees: [sam.id], at: now.addingTimeInterval(-4 * 86_400))
        store = InMemoryProposalStore(users: [sam, maya, leo, jalen, arlo, cleo], proposals: [open, surprise, locked, over],
                                      currentUserID: sam.id, now: { [unowned self] in self.clock })
    }

    private func become(_ user: User) async throws {
        await store.signOut()
        // signIn creates a fresh identity; the fixtures need a known one.
        store.seed(users: store.users, proposals: store.proposals, slots: store.slots, busyBlocks: store.busyBlocks,
                   places: store.places, votes: store.votes, currentUserID: user.id)
    }

    private func hint(_ work: () async throws -> Void) async -> String? {
        do { try await work(); return "no error" } catch let ProposalStoreError.server(_, _, hint) { return hint } catch { return "\(error)" }
    }

    // MARK: Who

    /// protects=you can poke someone you share a plan with and nobody else, and a stranger, a made-up
    /// id and yourself each get the server's refusal; fails_when=the demo store is more permissive
    /// than send_poke(); no_claim=the friends table that does not exist yet.
    func testOnlyPeopleYouShareAPlanWith() async throws {
        let receipt = try await store.sendPoke(to: maya.id, about: nil)
        XCTAssertTrue(receipt.isNew)
        let stranger = await hint { _ = try await store.sendPoke(to: arlo.id, about: nil) }
        XCTAssertEqual(stranger, "FC_NOT_FRIEND")
        let ghost = await hint { _ = try await store.sendPoke(to: UUID(), about: nil) }
        XCTAssertEqual(ghost, "FC_NOT_FRIEND")
        let myself = await hint { _ = try await store.sendPoke(to: sam.id, about: nil) }
        XCTAssertEqual(myself, "FC_SELF_POKE")
        XCTAssertEqual(store.pokes.count, 1)
        XCTAssertEqual(store.outbox.count, 1, "a refusal queues no push")
    }

    /// protects=sharing only a plan one of you is hidden from is not sharing a plan, so a poke cannot
    /// be used to reach across a surprise; demo friends are an explicit seed, not a loophole;
    /// fails_when=hidden_from stops gating the friend graph.
    func testAHiddenPlanIsNotAFriendship() async throws {
        var plan = surprise!
        plan.distribution.recipientIDs.append(arlo.id)
        store.seed(users: store.users, proposals: [plan], slots: [], currentUserID: arlo.id)
        let hidden = await hint { _ = try await store.sendPoke(to: jalen.id, about: nil) }
        XCTAssertEqual(hidden, "FC_NOT_FRIEND")
        _ = try await store.sendPoke(to: sam.id, about: nil)
        store.befriend([jalen.id], with: arlo.id)
        let seeded = try await store.sendPoke(to: jalen.id, about: nil)
        XCTAssertTrue(seeded.isNew)
    }

    // MARK: One live poke, one hour

    /// protects=one live poke per friend: a second send returns the first with isNew false and queues
    /// no second push; after the hour a new one goes; fails_when=a double tap or a second screen can
    /// stack pokes; no_claim=concurrency (the SQL lane's lock).
    func testOneLivePokePerFriendForAnHour() async throws {
        let first = try await store.sendPoke(to: maya.id, about: nil)
        XCTAssertEqual(first.poke.expiresAt, clock.addingTimeInterval(3600))
        clock.addTimeInterval(17 * 60)
        let again = try await store.sendPoke(to: maya.id, about: nil)
        XCTAssertFalse(again.isNew)
        XCTAssertEqual(again.poke.id, first.poke.id)
        XCTAssertEqual(store.outbox.filter { $0.recipientID == maya.id }.count, 1)
        let other = try await store.sendPoke(to: leo.id, about: nil)
        XCTAssertTrue(other.isNew, "a different friend is a different poke")

        clock.addTimeInterval(43 * 60)
        let afterTheHour = try await store.sendPoke(to: maya.id, about: nil)
        XCTAssertTrue(afterTheHour.isNew)
        XCTAssertEqual(store.pokes.filter { $0.toID == maya.id }.count, 2)
        XCTAssertEqual(store.outbox.first?.title, "Sam poked you")
        XCTAssertEqual(store.outbox.first?.route, .poke(first.poke.id))
        XCTAssertEqual(store.outbox.first?.expiresAt, first.poke.expiresAt, "the push dies with the poke")
    }

    // MARK: Acknowledge

    /// protects=only the recipient acknowledges, once, and never after the hour; someone else's poke
    /// is indistinguishable from none; fails_when=a second ack re-stamps the first, an expired poke
    /// turns "seen", or the sender can close their own poke.
    func testAcknowledgeIsTheRecipientsOnceAndInTime() async throws {
        let poke = try await store.sendPoke(to: maya.id, about: nil).poke
        let bySender = await hint { _ = try await store.acknowledgePoke(poke.id, via: .app) }
        XCTAssertEqual(bySender, "FC_POKE_NOT_FOUND")
        try await become(leo)
        let byOther = await hint { _ = try await store.acknowledgePoke(poke.id, via: .app) }
        XCTAssertEqual(byOther, "FC_POKE_NOT_FOUND")

        try await become(maya)
        clock.addTimeInterval(120)
        let seen = try await store.acknowledgePoke(poke.id, via: .push)
        XCTAssertEqual(seen.state(at: clock), .acknowledged(at: clock, via: .push))
        let first = clock
        clock.addTimeInterval(60)
        let again = try await store.acknowledgePoke(poke.id, via: .app)
        XCTAssertEqual(again.acknowledgedAt, first)
        XCTAssertEqual(again.ackVia, .push)

        try await become(sam)
        let second = try await store.sendPoke(to: maya.id, about: nil)
        XCTAssertTrue(second.isNew, "once acknowledged, the sender may poke again")
        clock.addTimeInterval(3601)
        try await become(maya)
        let late = try await store.acknowledgePoke(second.poke.id, via: .push)
        XCTAssertEqual(late.state(at: clock), .expired, "a push tapped after the hour does not reopen the poke")
        XCTAssertNil(late.acknowledgedAt)
    }

    /// protects=poking back is just poking: it answers theirs as `pokeBack` and leaves one live poke
    /// the other way; fails_when=poke back needs its own code path on some screen.
    func testPokingBackAnswersTheirs() async throws {
        let theirs = try await store.sendPoke(to: maya.id, about: nil).poke
        try await become(maya)
        let back = try await store.sendPoke(to: sam.id, about: nil)
        XCTAssertTrue(back.isNew)
        XCTAssertEqual(store.pokes.first { $0.id == theirs.id }?.ackVia, .pokeBack)
        let inbox = try await store.inbox()
        let feed = PokeFeed.build(inbox, me: maya.id, now: clock)
        XCTAssertTrue(feed.forYou.isEmpty)
        XCTAssertEqual(feed.sent.map(\.id), [back.poke.id])
        XCTAssertEqual(inbox.name(of: sam.id), "Sam")
    }

    // MARK: Plan context

    /// protects=a plan rides along only when BOTH people can read it; a poke "about" a plan the
    /// recipient is hidden from still goes, with no plan and a push that never names it;
    /// fails_when=a poke or its push can carry a surprise to the person it is for.
    func testAPlanIsContextNeverALeak() async throws {
        let about = try await store.sendPoke(to: leo.id, about: open.id)
        XCTAssertEqual(about.poke.proposalID, open.id)
        XCTAssertEqual(store.outbox.last?.body, "About Brunch. Poke back before it fades in an hour.")
        let hidden = try await store.sendPoke(to: jalen.id, about: surprise.id)
        XCTAssertTrue(hidden.isNew)
        XCTAssertNil(hidden.poke.proposalID)
        XCTAssertEqual(store.outbox.last?.body, "Poke back before it fades in an hour.")
        XCTAssertFalse(store.outbox.contains { $0.recipientID == jalen.id && ($0.title + $0.body).contains("Surprise") })
        try await become(jalen)
        let inbox = try await store.inbox()
        XCTAssertTrue(inbox.planTitles.isEmpty)
    }

    // MARK: Tag along

    /// protects=tagging along makes you a recipient and an attendee, gives you the plan's Busy block
    /// with its provenance, records the tag along and tells the host exactly once; a second tap
    /// changes nothing; fails_when=any of the five drifts from tag_along().
    func testTagAlongJoinsTheLockedPlanAndTellsTheHost() async throws {
        try await become(cleo)
        let joined = try await store.tagAlong(locked.id)
        XCTAssertTrue(joined.lockedAttendeeIDs.contains(cleo.id))
        XCTAssertEqual(joined.distribution.recipientIDs.filter { $0 == cleo.id }.count, 1)
        let block = try XCTUnwrap(store.busyBlocks.first { $0.userID == cleo.id })
        XCTAssertEqual(block.range, joined.lockedWindow)
        XCTAssertEqual(block.sourceProposalID, locked.id)
        XCTAssertEqual(store.tagAlongs.map(\.userID), [cleo.id])
        XCTAssertEqual(store.outbox.map(\.title), ["Cleo is tagging along"])
        XCTAssertEqual(store.outbox.first?.recipientID, sam.id)
        XCTAssertEqual(store.outbox.first?.body, "They just joined Tacos.")
        XCTAssertEqual(store.outbox.first?.route, .tagAlong(proposalID: locked.id))
        let mine = try await store.myCommitments(from: clock)
        XCTAssertEqual(mine.map(\.planTitle), ["Tacos"])

        _ = try await store.tagAlong(locked.id)
        XCTAssertEqual(store.busyBlocks.filter { $0.userID == cleo.id }.count, 1)
        XCTAssertEqual(store.outbox.count, 1)

        try await become(sam)
        let hostInbox = try await store.inbox()
        XCTAssertEqual(hostInbox.tagAlongs.map(\.planTitle), ["Tacos"])
        XCTAssertEqual(hostInbox.name(of: cleo.id), "Cleo")
    }

    /// protects=each refusal in the server's order with the server's hint: not locked, over, hidden
    /// (as not found), already busy; a refusal leaves no block, no attendee and no push;
    /// fails_when=the mirror disagrees with social.sql or a refused join leaves a trace.
    func testTagAlongRefusals() async throws {
        try await become(leo)
        let notLocked = await hint { _ = try await store.tagAlong(open.id) }
        XCTAssertEqual(notLocked, "FC_NOT_LOCKED")
        try await become(cleo)
        let finished = await hint { _ = try await store.tagAlong(over.id) }
        XCTAssertEqual(finished, "FC_PLAN_OVER")
        let ghost = await hint { _ = try await store.tagAlong(UUID()) }
        XCTAssertEqual(ghost, "FC_NOT_FOUND")

        var hiddenPlan = locked!
        hiddenPlan.hiddenFrom = [cleo.id]
        var busyThen = store.busyBlocks
        busyThen.append(BusyBlock(userID: leo.id, range: DateRange(lower: locked.lockedDate!.addingTimeInterval(3600),
                                                                 upper: locked.lockedEnd!.addingTimeInterval(3600))))
        store.seed(users: store.users, proposals: [open, hiddenPlan], slots: [], busyBlocks: busyThen, currentUserID: cleo.id)
        let hidden = await hint { _ = try await store.tagAlong(locked.id) }
        XCTAssertEqual(hidden, "FC_NOT_FOUND", "hidden reads exactly like a plan that is not there")

        store.seed(users: store.users, proposals: [open, locked], slots: [], busyBlocks: busyThen, currentUserID: leo.id)
        let busy = await hint { _ = try await store.tagAlong(locked.id) }
        XCTAssertEqual(busy, "FC_BUSY")
        XCTAssertEqual(store.busyBlocks.filter { $0.userID == leo.id }.count, 1)
        XCTAssertFalse(store.proposals.first { $0.id == locked.id }!.lockedAttendeeIDs.contains(leo.id))
        XCTAssertTrue(store.outbox.isEmpty)
    }

    /// protects=a watcher of the plan sees the new attendee without refetching, like every other
    /// mutation on a plan; fails_when=tagAlong stops emitting a snapshot.
    func testTagAlongEmitsASnapshot() async throws {
        try await become(cleo)
        var stream = store.changes(for: locked.id).makeAsyncIterator()
        _ = try await store.tagAlong(locked.id)
        guard case .snapshot(let snapshot)? = await stream.next() else { return XCTFail("no snapshot") }
        XCTAssertTrue(snapshot.proposal.lockedAttendeeIDs.contains(cleo.id))
    }

    // MARK: Devices

    /// protects=a token is stored for whoever registers it, moves when the phone changes hands, is
    /// refused when it is not a token, and is forgotten with the account; fails_when=a deleted
    /// account keeps a token or queued pushes.
    func testDeviceTokens() async throws {
        let token = String(repeating: "0123456789abcdef", count: 4)
        try await store.registerDevice(token: token.uppercased(), sandbox: true)
        XCTAssertEqual(store.deviceTokens, [token: sam.id])
        let bad = await hint { try await store.registerDevice(token: "not-a-token", sandbox: false) }
        XCTAssertEqual(bad, "FC_BAD_TOKEN")
        _ = try await store.sendPoke(to: maya.id, about: nil)

        try await become(maya)
        try await store.registerDevice(token: token, sandbox: false)
        XCTAssertEqual(store.deviceTokens, [token: maya.id])
        _ = try await store.deleteAccount()
        XCTAssertTrue(store.deviceTokens.isEmpty)
        XCTAssertFalse(store.outbox.contains { $0.recipientID == maya.id })
        store.seed(users: store.users, proposals: store.proposals, slots: [], currentUserID: sam.id)
        let gone = await hint { _ = try await store.sendPoke(to: maya.id, about: nil) }
        XCTAssertEqual(gone, "FC_NOT_FRIEND", "a deleted account reads like a stranger")
    }

    /// protects=every social operation honors the injected failure hook, so the screens' error paths
    /// can be driven without a network; fails_when=a new operation skips `authorize`.
    func testFailNextCoversTheSocialOperations() async throws {
        for op in [InMemoryProposalStore.Operation.sendPoke, .acknowledgePoke, .tagAlong, .inbox, .registerDevice] {
            store.failNext[op] = ProposalStoreError.network("down")
        }
        for work in [{ _ = try await self.store.sendPoke(to: self.maya.id, about: nil) },
                     { _ = try await self.store.acknowledgePoke(UUID(), via: .app) },
                     { _ = try await self.store.tagAlong(self.locked.id) },
                     { _ = try await self.store.inbox() },
                     { try await self.store.registerDevice(token: "ab", sandbox: true) }] as [() async throws -> Void] {
            do { try await work(); XCTFail("expected the injected failure") } catch { XCTAssertEqual(error as? ProposalStoreError, .network("down")) }
        }
    }
}
