import XCTest
@testable import FriendCalCore

/// The place calls of the in-memory store, rule for rule and refusal for refusal against #11's
/// contract (supabase/places.sql). Same SQLSTATE, same hint, same check order.
///
/// Cards. Each test says what it protects, what wrong result it rejects, and what green does not
/// prove. The real database is only exercised by the SQL lane.
@MainActor
final class InMemoryPlaceStoreTests: XCTestCase {
    private let sam = User(id: UUID(), displayName: "Sam")      // host
    private let maya = User(id: UUID(), displayName: "Maya")
    private let leo = User(id: UUID(), displayName: "Leo")
    private let pia = User(id: UUID(), displayName: "Pia")
    private let jalen = User(id: UUID(), displayName: "Jalen")  // a member the plan is hidden from
    private let nina = User(id: UUID(), displayName: "Nina")    // not on the plan at all
    private let quinn = User(id: UUID(), displayName: "Quinn")  // a sixth member, for the plan cap
    private let now = HeatmapTests.date(2026, 11, 8, 12)
    private let austin = SearchArea(name: "Austin, TX", latitude: 30.2672, longitude: -97.7431)
    private func mon(_ h: Int, _ m: Int = 0) -> Date { HeatmapTests.date(2026, 11, 9, h, m) }
    private var window: DateRange { DateRange(lower: mon(0), upper: HeatmapTests.date(2026, 11, 23, 0)) }

    private func makeStore(status: ProposalStatus = .requesting, area: SearchArea? = nil, hidden: [UUID] = [],
                           hasArea: Bool = true, as user: User? = nil) -> (InMemoryProposalStore, Proposal) {
        let p = Proposal(id: UUID(), title: "Brunch", window: window, createdBy: sam.id,
                         distribution: Distribution(mode: .newGroup, recipientIDs: [sam, maya, leo, pia, jalen, quinn].map(\.id)),
                         status: status, area: hasArea ? (area ?? austin) : nil, expectedCount: 5, hiddenFrom: hidden)
        let s = InMemoryProposalStore(users: [sam, maya, leo, pia, jalen, quinn, nina], proposals: [p], currentUserID: (user ?? maya).id, now: { [now] in now })
        return (s, p)
    }

    /// Switches identity without touching any row.
    private func act(_ s: InMemoryProposalStore, as user: User) {
        s.seed(users: s.users, proposals: s.proposals, slots: s.slots, busyBlocks: s.busyBlocks, places: s.places, votes: s.votes, currentUserID: user.id)
    }

    private func place(_ name: String, lat: Double = 30.27, lon: Double = -97.74, ref: String? = nil) -> NewPlace {
        NewPlace(name: name, latitude: lat, longitude: lon, mapRef: ref)
    }

    private struct Refusal: Equatable { var code: String; var hint: String?; var message: String }
    private func refusal(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> Refusal? {
        do { try await body(); return nil } catch ProposalStoreError.server(let code, let message, let hint) {
            return Refusal(code: code, hint: hint, message: message)
        } catch { XCTFail("expected a server refusal, got \(error)", file: file, line: line); return nil }
    }

    // MARK: suggest

    /// protects=a member's suggestion is stored with the caller, a timestamp from the injected clock and
    /// trimmed fields, and reaches subscribers; fails_when=the row is stored untrimmed, attributed
    /// to someone else, or no snapshot is emitted; no_claim=Realtime delivery.
    func testSuggestStoresATrimmedPlaceAndEmitsASnapshot() async throws {
        let (s, p) = makeStore()
        var changes = s.changes(for: p.id).makeAsyncIterator()
        let saved = try await s.suggestPlace(proposalID: p.id, NewPlace(name: "  Cafe Lola  ", address: "   ", latitude: 30.27, longitude: -97.74, mapRef: " "))
        XCTAssertEqual(saved.name, "Cafe Lola")
        XCTAssertNil(saved.address, "a blank address becomes nil")
        XCTAssertNil(saved.mapRef, "a blank map reference becomes nil")
        XCTAssertEqual(saved.suggestedBy, maya.id)
        XCTAssertEqual(saved.createdAt, now)
        guard case .snapshot(let snapshot)? = await changes.next() else { return XCTFail("no snapshot") }
        XCTAssertEqual(snapshot.places, [saved])
        XCTAssertEqual(try s.snapshot(of: p.id).places, [saved])
    }

    /// protects=the guard's order: not signed in, then plan/exclusion (one raise), then membership,
    /// then status; fails_when=a non-member who is not excluded gets NOT_FOUND, or locked is reported
    /// before membership; no_claim=timing differences between the paths.
    func testGuardOrderAndCodes() async throws {
        let (s, p) = makeStore(hidden: [jalen.id])
        act(s, as: nina)
        let notMember = await refusal { _ = try await s.suggestPlace(proposalID: p.id, place("X")) }
        XCTAssertEqual(notMember?.code, "42501"); XCTAssertEqual(notMember?.hint, "FC_NOT_MEMBER")
        let ghost = await refusal { _ = try await s.suggestPlace(proposalID: UUID(), place("X")) }
        XCTAssertEqual(ghost?.code, "P0002"); XCTAssertEqual(ghost?.hint, "FC_NOT_FOUND")

        let (closed, cp) = makeStore(status: .locked)
        let locked = await refusal { _ = try await closed.suggestPlace(proposalID: cp.id, place("X")) }
        XCTAssertEqual(locked?.code, "55000"); XCTAssertEqual(locked?.hint, "FC_LOCKED")
        let (cancelled, xp) = makeStore(status: .cancelled)
        let gone = await refusal { _ = try await cancelled.suggestPlace(proposalID: xp.id, place("X")) }
        XCTAssertEqual(gone?.code, "55000"); XCTAssertEqual(gone?.hint, "FC_CLOSED")

        let signedOut = InMemoryProposalStore(users: [sam], proposals: [p], currentUserID: nil, now: { [now] in now })
        do { _ = try await signedOut.suggestPlace(proposalID: p.id, place("X")); XCTFail("signed out") } catch {
            XCTAssertEqual(error as? ProposalStoreError, .notSignedIn)
        }
    }

    /// protects=an excluded caller gets exactly the error an unknown plan or place gets, for all four
    /// calls; fails_when=any call raises a different code, hint or message for the excluded caller, or
    /// the check uses isReadable(by:); no_claim=timing, which the in-memory store cannot show.
    func testExcludedCallerIsToldWhatAStrangerIsTold() async throws {
        let (s, p) = makeStore(hidden: [jalen.id])
        let real = try await s.suggestPlace(proposalID: p.id, place("Real"))
        let unknown = await refusal { _ = try await s.suggestPlace(proposalID: UUID(), place("X")) }
        act(s, as: jalen)
        let suggest = await refusal { _ = try await s.suggestPlace(proposalID: p.id, place("X")) }
        let vote = await refusal { try await s.votePlace(proposalID: p.id, placeID: real.id) }
        let clear = await refusal { try await s.votePlace(proposalID: p.id, placeID: nil) }
        let veto = await refusal { _ = try await s.vetoPlace(placeID: real.id, vetoed: true) }
        let remove = await refusal { try await s.removePlace(placeID: real.id) }
        XCTAssertEqual(unknown?.hint, "FC_NOT_FOUND")
        for (name, got) in [("suggest", suggest), ("vote", vote), ("clear", clear), ("veto", veto), ("remove", remove)] {
            XCTAssertEqual(got, unknown, "\(name): the excluded caller must see the unknown-plan error")
        }
        act(s, as: sam)
        let missingPlace = await refusal { _ = try await s.vetoPlace(placeID: UUID(), vetoed: true) }
        XCTAssertEqual(missingPlace, unknown, "an unknown place id is the same raise")
    }

    /// protects=a plan with no city refuses with FC_NO_AREA before any field is judged; fails_when=a
    /// bad place on a cityless plan reports FC_BAD_PLACE; no_claim=none beyond protects.
    func testNoCityRefusesFirst() async throws {
        let (s, p) = makeStore(hasArea: false)
        let r = await refusal { _ = try await s.suggestPlace(proposalID: p.id, NewPlace(name: " ", latitude: 0, longitude: 0)) }
        XCTAssertEqual(r?.code, "P0001"); XCTAssertEqual(r?.hint, "FC_NO_AREA")
    }

    /// protects=every invalid-field branch is FC_BAD_PLACE under 22023, with the SQL's trimming and
    /// code-point counting; fails_when=a blank name, 121 characters, a long address or reference, a
    /// bad coordinate or NaN is accepted, or a name of 61 combining pairs (122 code points) passes;
    /// no_claim=whether the place exists.
    func testInvalidFieldsAreBadPlace() async throws {
        let (s, p) = makeStore()
        func bad(_ n: NewPlace) async -> Refusal? { await refusal { _ = try await s.suggestPlace(proposalID: p.id, n) } }
        let cases: [NewPlace] = [
            place("   "), place(String(repeating: "n", count: 121)),
            place(String(repeating: "e\u{0301}", count: 61)),
            NewPlace(name: "V", address: String(repeating: "a", count: 241), latitude: 1, longitude: 1),
            NewPlace(name: "V", latitude: 1, longitude: 1, mapRef: String(repeating: "m", count: 201)),
            NewPlace(name: "V", latitude: 91, longitude: 1), NewPlace(name: "V", latitude: 1, longitude: -180.5),
            NewPlace(name: "V", latitude: .nan, longitude: 1), NewPlace(name: "V", latitude: 1, longitude: .infinity),
        ]
        for c in cases {
            let r = await bad(c)
            XCTAssertEqual(r?.code, "22023", c.name); XCTAssertEqual(r?.hint, "FC_BAD_PLACE", c.name)
        }
        _ = try await s.suggestPlace(proposalID: p.id, place(String(repeating: "n", count: 120)))
    }

    /// protects=a repeat of an active place returns the existing row, a repeat of only a vetoed place
    /// is refused, and an active match beats a vetoed one; fails_when=a duplicate row is created or a
    /// veto can be bypassed by re-suggesting; no_claim=matches more than 110 m apart.
    func testDuplicatesAndVetoedDuplicates() async throws {
        let (s, p) = makeStore()
        let first = try await s.suggestPlace(proposalID: p.id, place("Cafe Lola", ref: "M1"))
        act(s, as: leo)
        let byRef = try await s.suggestPlace(proposalID: p.id, place("Totally different", lat: 40, lon: -100, ref: "M1"))
        let byName = try await s.suggestPlace(proposalID: p.id, place("CAFE LOLA", lat: 30.2705, lon: -97.7395))
        XCTAssertEqual(byRef.id, first.id); XCTAssertEqual(byName.id, first.id)
        XCTAssertEqual(s.places.count, 1)
        act(s, as: sam)
        _ = try await s.vetoPlace(placeID: first.id, vetoed: true)
        act(s, as: pia)
        let again = await refusal { _ = try await s.suggestPlace(proposalID: p.id, place("Cafe Lola")) }
        XCTAssertEqual(again?.code, "P0001"); XCTAssertEqual(again?.hint, "FC_VETOED")
        let dup = Place(id: UUID(), proposalID: p.id, suggestedBy: leo.id, name: "Cafe Lola", latitude: 30.27, longitude: -97.74, createdAt: now)
        s.seed(users: s.users, proposals: s.proposals, slots: [], places: s.places + [dup], votes: [], currentUserID: pia.id)
        let active = try await s.suggestPlace(proposalID: p.id, place("Cafe Lola"))
        XCTAssertEqual(active.id, dup.id, "an active match beats a vetoed one")
    }

    /// protects=the personal cap (2) is reported before the plan cap (10), vetoed and withdrawn places
    /// do not count; fails_when=a cap counts vetoed rows or reports in the other order; no_claim=the
    /// numbers as product choices.
    func testCaps() async throws {
        let (s, p) = makeStore()
        let friends = [sam, maya, leo, pia, jalen]
        var ids: [UUID: [UUID]] = [:]
        for (i, u) in friends.enumerated() {
            act(s, as: u)
            for k in 0..<2 { ids[u.id, default: []].append(try await s.suggestPlace(proposalID: p.id, place("S\(i)-\(k)", lat: 30.1 + Double(i) * 0.1 + Double(k) * 0.01)).id) }
        }
        act(s, as: maya)
        let personal = await refusal { _ = try await s.suggestPlace(proposalID: p.id, place("third", lat: 31.5)) }
        XCTAssertEqual(personal?.code, "54000"); XCTAssertEqual(personal?.hint, "FC_PLACE_LIMIT", "personal cap first")
        act(s, as: quinn)
        let full = await refusal { _ = try await s.suggestPlace(proposalID: p.id, place("eleventh", lat: 31.6)) }
        XCTAssertEqual(full?.code, "54000"); XCTAssertEqual(full?.hint, "FC_PLAN_FULL")
        act(s, as: sam)
        _ = try await s.vetoPlace(placeID: ids[maya.id]![0], vetoed: true)
        act(s, as: maya)
        _ = try await s.suggestPlace(proposalID: p.id, place("maya again", lat: 31.8))
        act(s, as: leo)
        try await s.removePlace(placeID: ids[leo.id]![0])
        _ = try await s.suggestPlace(proposalID: p.id, place("leo again", lat: 31.9))
    }

    // MARK: vote

    /// protects=one vote per person: move and clear work, a repeated vote keeps its timestamp, a self
    /// vote, a vetoed place and a place on another plan are refused with the SQL's codes; fails_when=two
    /// vote rows for one person, a self-vote is accepted, or a repeat rewrites created_at;
    /// no_claim=whether the UI offers a self-vote button.
    func testVoteRules() async throws {
        let (s, p) = makeStore()
        act(s, as: leo)
        let a = try await s.suggestPlace(proposalID: p.id, place("A"))
        act(s, as: pia)
        let b = try await s.suggestPlace(proposalID: p.id, place("B", lat: 30.3))
        let c = try await s.suggestPlace(proposalID: p.id, place("C", lat: 30.4))
        act(s, as: maya)
        try await s.votePlace(proposalID: p.id, placeID: a.id)
        XCTAssertEqual(s.votes.count, 1)
        let firstTime = s.votes[0].createdAt
        s.now = { [now] in now.addingTimeInterval(60) }
        try await s.votePlace(proposalID: p.id, placeID: a.id)
        XCTAssertEqual(s.votes[0].createdAt, firstTime, "a repeated vote changes nothing, including its time")
        try await s.votePlace(proposalID: p.id, placeID: b.id)
        XCTAssertEqual(s.votes.filter { $0.voterID == maya.id }.map(\.placeID), [b.id], "moved, still one vote")
        XCTAssertGreaterThan(s.votes[0].createdAt, firstTime)
        act(s, as: pia)
        let own = await refusal { try await s.votePlace(proposalID: p.id, placeID: c.id) }
        XCTAssertEqual(own?.code, "42501"); XCTAssertEqual(own?.hint, "FC_OWN_PLACE")
        act(s, as: sam)
        _ = try await s.vetoPlace(placeID: c.id, vetoed: true)
        act(s, as: maya)
        let vetoed = await refusal { try await s.votePlace(proposalID: p.id, placeID: c.id) }
        XCTAssertEqual(vetoed?.code, "P0001"); XCTAssertEqual(vetoed?.hint, "FC_VETOED")
        let elsewhere = await refusal { try await s.votePlace(proposalID: p.id, placeID: UUID()) }
        XCTAssertEqual(elsewhere?.code, "P0002"); XCTAssertEqual(elsewhere?.hint, "FC_PLACE_NOT_FOUND")
        try await s.votePlace(proposalID: p.id, placeID: nil)
        XCTAssertTrue(s.votes.filter { $0.voterID == maya.id }.isEmpty)
        try await s.votePlace(proposalID: p.id, placeID: nil)   // clearing nothing is a no-op
    }

    // MARK: veto / bring back / withdraw

    /// protects=only the host vetoes; a veto clears the votes on that place and nothing else; a repeat
    /// does not restamp; bringing back restores zero votes; fails_when=a friend vetoes, orphan votes
    /// survive, or votes come back; no_claim=vote history after a veto, deliberately not kept.
    func testVetoCycle() async throws {
        let (s, p) = makeStore()
        act(s, as: leo)
        let target = try await s.suggestPlace(proposalID: p.id, place("Target"))
        let keep = try await s.suggestPlace(proposalID: p.id, place("Keep", lat: 30.3))
        act(s, as: maya); try await s.votePlace(proposalID: p.id, placeID: target.id)
        act(s, as: pia); try await s.votePlace(proposalID: p.id, placeID: target.id)
        act(s, as: jalen); try await s.votePlace(proposalID: p.id, placeID: keep.id)
        act(s, as: leo)
        let friend = await refusal { _ = try await s.vetoPlace(placeID: target.id, vetoed: true) }
        XCTAssertEqual(friend?.code, "42501"); XCTAssertEqual(friend?.hint, "FC_NOT_CREATOR")
        act(s, as: sam)
        let vetoed = try await s.vetoPlace(placeID: target.id, vetoed: true)
        XCTAssertNotNil(vetoed.vetoedAt)
        XCTAssertTrue(s.votes.filter { $0.placeID == target.id }.isEmpty)
        XCTAssertEqual(s.votes.filter { $0.placeID == keep.id }.count, 1)
        s.now = { [now] in now.addingTimeInterval(600) }
        let again = try await s.vetoPlace(placeID: target.id, vetoed: true)
        XCTAssertEqual(again.vetoedAt, vetoed.vetoedAt, "a second veto does not restamp")
        let back = try await s.vetoPlace(placeID: target.id, vetoed: false)
        XCTAssertNil(back.vetoedAt)
        XCTAssertTrue(s.votes.filter { $0.placeID == target.id }.isEmpty, "brought back with zero votes")
        let noop = try await s.vetoPlace(placeID: target.id, vetoed: false)
        XCTAssertEqual(noop, back)
    }

    /// protects=bringing a place back respects both caps; fails_when=unveto skips a cap check;
    /// no_claim=none beyond protects.
    func testBringBackRespectsCaps() async throws {
        let (s, p) = makeStore()
        act(s, as: leo)
        let first = try await s.suggestPlace(proposalID: p.id, place("L1"))
        act(s, as: sam); _ = try await s.vetoPlace(placeID: first.id, vetoed: true)
        act(s, as: leo)
        _ = try await s.suggestPlace(proposalID: p.id, place("L2", lat: 30.3))
        _ = try await s.suggestPlace(proposalID: p.id, place("L3", lat: 30.4))
        act(s, as: sam)
        let personal = await refusal { _ = try await s.vetoPlace(placeID: first.id, vetoed: false) }
        XCTAssertEqual(personal?.code, "54000"); XCTAssertEqual(personal?.hint, "FC_PLACE_LIMIT")

        let (t, tp) = makeStore()
        let passed = Place(id: UUID(), proposalID: tp.id, suggestedBy: pia.id, name: "Passed", latitude: 1, longitude: 1, vetoedAt: now, createdAt: now)
        let ten = (0..<10).map { Place(id: UUID(), proposalID: tp.id, suggestedBy: [leo, maya, jalen, sam][$0 % 4].id, name: "Full \($0)", latitude: Double($0), longitude: 0, createdAt: now) }
        t.seed(users: t.users, proposals: t.proposals, slots: [], places: ten + [passed], votes: [], currentUserID: sam.id)
        let full = await refusal { _ = try await t.vetoPlace(placeID: passed.id, vetoed: false) }
        XCTAssertEqual(full?.code, "54000"); XCTAssertEqual(full?.hint, "FC_PLAN_FULL")
    }

    /// protects=only the suggester withdraws and the votes go with the place; fails_when=the host or a
    /// friend removes someone else's place or votes survive; no_claim=soft-delete semantics.
    func testWithdraw() async throws {
        let (s, p) = makeStore()
        act(s, as: leo)
        let mine = try await s.suggestPlace(proposalID: p.id, place("Mine"))
        act(s, as: maya); try await s.votePlace(proposalID: p.id, placeID: mine.id)
        for stranger in [maya, sam] {
            act(s, as: stranger)
            let r = await refusal { try await s.removePlace(placeID: mine.id) }
            XCTAssertEqual(r?.code, "42501"); XCTAssertEqual(r?.hint, "FC_NOT_YOUR_PLACE")
        }
        act(s, as: leo)
        try await s.removePlace(placeID: mine.id)
        XCTAssertTrue(s.places.isEmpty); XCTAssertTrue(s.votes.isEmpty)
        let gone = await refusal { try await s.removePlace(placeID: mine.id) }
        XCTAssertEqual(gone?.hint, "FC_NOT_FOUND")
    }

    /// protects=locked and cancelled plans refuse all four calls; fails_when=any call succeeds after
    /// lock; no_claim=plans in states the fixtures do not produce.
    func testClosedPlansRefuseEverything() async throws {
        for (status, hint) in [(ProposalStatus.locked, "FC_LOCKED"), (.cancelled, "FC_CLOSED")] {
            let (s, p) = makeStore(status: status)
            let seeded = Place(id: UUID(), proposalID: p.id, suggestedBy: maya.id, name: "P", latitude: 1, longitude: 1, createdAt: now)
            s.seed(users: s.users, proposals: s.proposals, slots: [], places: [seeded], votes: [], currentUserID: maya.id)
            let suggest = await refusal { _ = try await s.suggestPlace(proposalID: p.id, place("X")) }
            let vote = await refusal { try await s.votePlace(proposalID: p.id, placeID: seeded.id) }
            let remove = await refusal { try await s.removePlace(placeID: seeded.id) }
            act(s, as: sam)
            let veto = await refusal { _ = try await s.vetoPlace(placeID: seeded.id, vetoed: true) }
            for (name, r) in [("suggest", suggest), ("vote", vote), ("remove", remove), ("veto", veto)] {
                XCTAssertEqual(r?.code, "55000", "\(status) \(name)"); XCTAssertEqual(r?.hint, hint, "\(status) \(name)")
            }
        }
    }

    // MARK: lock, delete, city

    private func lockReady(votesFor: (Place, Place) -> [(User, Place)]) async throws -> (InMemoryProposalStore, Proposal, Place, Place) {
        let (s, p) = makeStore()
        let holds = [sam, maya, leo, pia, jalen].map { u in
            AvailabilitySlot(userID: u.id, range: DateRange(lower: mon(17), upper: mon(21)), sourceProposalID: p.id, state: .softHold, createdAt: now)
        }
        s.seed(users: s.users, proposals: s.proposals, slots: holds, places: [], votes: [], currentUserID: leo.id)
        let a = try await s.suggestPlace(proposalID: p.id, place("A"))
        act(s, as: pia)
        s.now = { [now] in now.addingTimeInterval(60) }
        let b = try await s.suggestPlace(proposalID: p.id, place("B", lat: 30.3))
        for (user, chosen) in votesFor(a, b) { act(s, as: user); try await s.votePlace(proposalID: p.id, placeID: chosen.id) }
        act(s, as: sam)
        return (s, p, a, b)
    }

    /// protects=the lock stores the winner chosen by the one rule in the same mutation as the status,
    /// and stores nil when nothing has a vote; fails_when=the winner is set separately or after the
    /// status, recounted at read time, or a vetoed leader is stored; no_claim=the Postgres transaction.
    func testLockStoresTheWinnerWithTheStatus() async throws {
        let (s, p, a, b) = try await lockReady { a, b in [(self.maya, b), (self.jalen, b), (self.sam, a)] }
        var changes = s.changes(for: p.id).makeAsyncIterator()
        let locked = try await s.lock(p.id, window: DateRange(lower: mon(18), upper: mon(19, 30)))
        XCTAssertEqual(locked.status, .locked)
        XCTAssertEqual(locked.lockedPlaceID, b.id)
        guard case .snapshot(let snap)? = await changes.next() else { return XCTFail("no snapshot") }
        XCTAssertEqual(snap.proposal.lockedPlaceID, b.id, "the first snapshot after the lock already carries the winner")
        XCTAssertEqual(snap.places.map(\.id).sorted { $0.uuidString < $1.uuidString }, [a.id, b.id].sorted { $0.uuidString < $1.uuidString })

        let (none, np, _, _) = try await lockReady { _, _ in [] }
        let unvoted = try await none.lock(np.id, window: DateRange(lower: mon(18), upper: mon(19, 30)))
        XCTAssertNil(unvoted.lockedPlaceID, "no votes, no winner")

        let (veto, vp, va, _) = try await lockReady { a, b in [(self.maya, a), (self.jalen, a), (self.sam, b)] }
        _ = try await veto.vetoPlace(placeID: va.id, vetoed: true)
        let afterVeto = try await veto.lock(vp.id, window: DateRange(lower: mon(18), upper: mon(19, 30)))
        XCTAssertNotNil(afterVeto.lockedPlaceID)
        XCTAssertNotEqual(afterVeto.lockedPlaceID, va.id, "a vetoed leader is never stored")
    }

    /// protects=a leaver's votes on collecting plans go, votes on locked and cancelled plans stay,
    /// suggestions stay; fails_when=a departed person's vote still decides a winner or a locked tally
    /// changes; no_claim=the SQL cascade, covered by #11.
    func testDeleteAccountRemovesVotesOnCollectingPlansOnly() async throws {
        let (s, p) = makeStore()
        act(s, as: leo)
        let theirs = try await s.suggestPlace(proposalID: p.id, place("Leo's"))
        act(s, as: maya)
        let hers = try await s.suggestPlace(proposalID: p.id, place("Maya's", lat: 30.3))
        try await s.votePlace(proposalID: p.id, placeID: theirs.id)
        let lockedPlan = Proposal(id: UUID(), title: "Done", window: window, createdBy: sam.id,
                                  distribution: Distribution(mode: .newGroup, recipientIDs: [sam.id, maya.id]), status: .locked, area: austin, expectedCount: 2)
        let held = Place(id: UUID(), proposalID: lockedPlan.id, suggestedBy: sam.id, name: "Frozen", latitude: 1, longitude: 1, createdAt: now)
        let frozenVote = PlaceVote(proposalID: lockedPlan.id, voterID: maya.id, placeID: held.id, createdAt: now)
        s.seed(users: s.users, proposals: s.proposals + [lockedPlan], slots: [], places: s.places + [held], votes: s.votes + [frozenVote], currentUserID: maya.id)
        act(s, as: leo); try await s.votePlace(proposalID: p.id, placeID: hers.id)
        act(s, as: maya)
        let receipt = try await s.deleteAccount()
        XCTAssertFalse(receipt.alreadyDeleted)
        XCTAssertTrue(s.votes.filter { $0.voterID == maya.id && $0.proposalID == p.id }.isEmpty, "the collecting plan's vote is gone")
        XCTAssertEqual(s.votes.filter { $0.voterID == maya.id && $0.proposalID == lockedPlan.id }.count, 1, "the locked plan's vote stays")
        XCTAssertEqual(s.votes.filter { $0.voterID == leo.id }.count, 1, "other people's votes are untouched")
        XCTAssertTrue(s.places.contains { $0.id == hers.id }, "a leaver's suggestion stays")
        XCTAssertEqual(s.users.first { $0.id == maya.id }?.displayName, User.deletedDisplayName)
    }

    /// protects=the host's city is set at create, replaced while requesting even with the dates frozen,
    /// never cleared, and invalid cities raise 23514 as Postgres would; fails_when=a clear succeeds, a
    /// blank-named city is stored, or a frozen-dates edit drops the city change; no_claim=whether the
    /// city is real.
    func testCityRules() async throws {
        let s = InMemoryProposalStore(users: [sam], currentUserID: sam.id, now: { [now] in now })
        let created = try await s.create(NewProposal(title: "Brunch", window: window, expectedCount: 4, area: austin))
        XCTAssertEqual(created.area, austin)
        for bad in [SearchArea(name: " ", latitude: 1, longitude: 1), SearchArea(name: String(repeating: "a", count: 121), latitude: 1, longitude: 1),
                    SearchArea(name: "X", latitude: 91, longitude: 0)] {
            let r = await refusal { _ = try await s.create(NewProposal(title: "B", window: window, expectedCount: 4, area: bad)) }
            XCTAssertEqual(r?.code, "23514"); XCTAssertNil(r?.hint)
        }
        let padded = SearchArea(name: "  " + String(repeating: "a", count: 120) + "  ", latitude: 1, longitude: 1)
        _ = try await s.create(NewProposal(title: "B", window: window, expectedCount: 4, area: padded))

        // Freeze the dates with a hold, then change only the city.
        let hold = AvailabilitySlot(userID: sam.id, range: DateRange(lower: mon(9), upper: mon(11)), sourceProposalID: created.id, state: .softHold, createdAt: now)
        s.seed(users: s.users, proposals: s.proposals, slots: [hold], currentUserID: sam.id)
        var edited = created
        edited.area = SearchArea(name: "Dallas, TX", latitude: 32.7767, longitude: -96.797)
        let moved = try await s.update(edited)
        XCTAssertEqual(moved.area?.name, "Dallas, TX", "the city changes while the dates are frozen")
        edited.area = nil
        let cleared = await refusal { _ = try await s.update(edited) }
        XCTAssertEqual(cleared?.code, "22023"); XCTAssertEqual(cleared?.hint, "FC_AREA_REQUIRED")
        XCTAssertEqual(s.proposals.first { $0.id == created.id }?.area?.name, "Dallas, TX")
        edited.area = SearchArea(name: "", latitude: 0, longitude: 0)
        let invalid = await refusal { _ = try await s.update(edited) }
        XCTAssertEqual(invalid?.code, "23514")

        // A plan that predates places has no city and can still be edited without one.
        let legacy = Proposal(id: UUID(), title: "Old", window: window, createdBy: sam.id, distribution: Distribution(mode: .newGroup, recipientIDs: [sam.id]), expectedCount: 2)
        s.seed(users: s.users, proposals: [legacy], slots: [], currentUserID: sam.id)
        var renamed = legacy; renamed.title = "Older"
        let saved = try await s.update(renamed)
        XCTAssertNil(saved.area)
        XCTAssertEqual(saved.title, "Older")

        let (locked, lp) = makeStore(status: .locked)
        act(locked, as: sam)
        var change = lp; change.area = SearchArea(name: "Waco, TX", latitude: 31.5, longitude: -97.1)
        let frozen = await refusal { _ = try await locked.update(change) }
        XCTAssertEqual(frozen?.code, "55000"); XCTAssertEqual(frozen?.hint, "FC_LOCKED")
    }

    /// protects=-FriendCalFailNext works for each place operation, once; fails_when=an operation skips
    /// its gate; no_claim=the launch argument parsing (#14).
    func testFailNextPerOperation() async throws {
        let (s, p) = makeStore()
        let boom = ProposalStoreError.network("boom")
        s.failNext[.suggestPlace] = boom
        do { _ = try await s.suggestPlace(proposalID: p.id, place("X")); XCTFail() } catch { XCTAssertEqual(error as? ProposalStoreError, boom) }
        let saved = try await s.suggestPlace(proposalID: p.id, place("X"))
        s.failNext[.votePlace] = boom
        act(s, as: leo)
        do { try await s.votePlace(proposalID: p.id, placeID: saved.id); XCTFail() } catch { XCTAssertEqual(error as? ProposalStoreError, boom) }
        act(s, as: sam)
        s.failNext[.vetoPlace] = boom
        do { _ = try await s.vetoPlace(placeID: saved.id, vetoed: true); XCTFail() } catch { XCTAssertEqual(error as? ProposalStoreError, boom) }
        act(s, as: maya)
        s.failNext[.removePlace] = boom
        do { try await s.removePlace(placeID: saved.id); XCTFail() } catch { XCTAssertEqual(error as? ProposalStoreError, boom) }
    }

    /// protects=a place the host passed on cannot be withdrawn (FC_VETOED, the row stays), re-suggesting
    /// it is still refused, and once the host brings it back the suggester can withdraw it; fails_when=
    /// withdrawing deletes the vetoed row and the same place comes back as an active one; why_new=the
    /// withdraw tests only cover active places; no_claim=the SQL, covered by places_test.sql section 16.
    func testAPassedOnPlaceCannotBeWithdrawn() async throws {
        let (s, p) = makeStore()
        act(s, as: leo)
        let mine = try await s.suggestPlace(proposalID: p.id, place("Target"))
        act(s, as: sam)
        _ = try await s.vetoPlace(placeID: mine.id, vetoed: true)
        act(s, as: leo)
        let withdrawn = await refusal { try await s.removePlace(placeID: mine.id) }
        XCTAssertEqual(withdrawn, Refusal(code: "P0001", hint: "FC_VETOED", message: "the host passed on that place"))
        XCTAssertTrue(s.places.contains { $0.id == mine.id && $0.isVetoed }, "the passed-on row stays")
        act(s, as: pia)
        let again = await refusal { _ = try await s.suggestPlace(proposalID: p.id, place("Target")) }
        XCTAssertEqual(again?.hint, "FC_VETOED", "re-suggesting is still refused")
        act(s, as: sam)
        _ = try await s.vetoPlace(placeID: mine.id, vetoed: false)
        act(s, as: leo)
        try await s.removePlace(placeID: mine.id)
        XCTAssertFalse(s.places.contains { $0.id == mine.id }, "after the host brings it back it can be withdrawn")
    }

    /// protects=a deleted account is refused FC_ACCOUNT_DELETED by every place call, even from a stale
    /// session that still holds its id (the guard's is-active step); fails_when=a tombstone can still
    /// suggest, vote, pass on or withdraw a place; why_new=the delete tests only check that votes go;
    /// no_claim=the SQL guard, covered by places_test.sql section 13.
    func testPlaceCallsAreRefusedForADeletedAccount() async throws {
        let (s, p) = makeStore()
        act(s, as: leo)
        let theirs = try await s.suggestPlace(proposalID: p.id, place("Leo's"))
        act(s, as: maya)
        _ = try await s.deleteAccount()
        act(s, as: maya)   // a stale session still holding the deleted id
        let gone = Refusal(code: "42501", hint: "FC_ACCOUNT_DELETED", message: "this account has been deleted")
        let suggested = await refusal { _ = try await s.suggestPlace(proposalID: p.id, place("Late")) }
        XCTAssertEqual(suggested, gone, "suggest")
        let voted = await refusal { try await s.votePlace(proposalID: p.id, placeID: theirs.id) }
        XCTAssertEqual(voted, gone, "vote")
        let vetoed = await refusal { _ = try await s.vetoPlace(placeID: theirs.id, vetoed: true) }
        XCTAssertEqual(vetoed, gone, "veto")
        let removed = await refusal { try await s.removePlace(placeID: theirs.id) }
        XCTAssertEqual(removed, gone, "remove")
        XCTAssertEqual(s.places.count, 1, "nothing was written")
    }
}
