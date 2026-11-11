import XCTest
@testable import FriendCalCore

/// Add a friend, core lane (docs/designs/friendcal-add-friend-spec.md sections 5, 7, 8). The server
/// side is supabase/tests/friends_test.sql; `InMemoryFriendStoreTests` below asserts the same cases
/// against the in-memory store, which mirrors friends.sql answer for answer.
final class FriendDeepLinkTests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQr_-12"
    private let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000900")!

    /// protects=both friend forms and the plan https form parse to one case each, and anything near
    /// them (wrong host, extra path parts, a 21 or 23 character token, http, a port) opens nothing;
    /// fails_when=the host is matched loosely, the token length or alphabet drifts, or a path part is ignored;
    /// why_new=DeepLinkTests covers the plan scheme only; seam=none; no_claim=iOS routing the URL to the app.
    func testParseTable() {
        let rows: [(String, DeepLink?)] = [
            ("friendcal://friend/\(token)", .friend(token)),
            ("FRIENDCAL://FRIEND/\(token)", .friend(token)),
            ("https://friendcal.app/f/\(token)", .friend(token)),
            ("https://FriendCal.app/f/\(token)", .friend(token)),
            ("https://friendcal.app/f/\(token)/", .friend(token)),
            ("https://friendcal.app/p/\(planID.uuidString)", .proposal(planID)),
            ("friendcal://friend/\(token)?n=Sam", .friend(token, name: "Sam")),
            ("https://friendcal.app/f/\(token)?n=Sam", .friend(token, name: "Sam")),
            ("https://friendcal.app/p/\(planID.uuidString)?t=Brunch", .proposal(planID, title: "Brunch")),
            // wrong host, scheme, port, credentials
            ("https://friendcal.app.evil.com/f/\(token)", nil),
            ("https://evil.com/f/\(token)", nil),
            ("https://www.friendcal.app/f/\(token)", nil),
            ("http://friendcal.app/f/\(token)", nil),
            ("https://friendcal.app:8443/f/\(token)", nil),
            ("https://user@friendcal.app/f/\(token)", nil),
            // extra or missing path parts
            ("https://friendcal.app/f/\(token)/extra", nil),
            ("https://friendcal.app/f", nil),
            ("https://friendcal.app/x/\(token)", nil),
            ("https://friendcal.app/f/\(planID.uuidString)", nil),
            ("friendcal://friend/\(token)/extra", nil),
            ("friendcal://friend", nil),
            ("friendcal://friends/\(token)", nil),
            // token length and alphabet
            ("friendcal://friend/\(String(token.dropLast()))", nil),
            ("friendcal://friend/\(token)A", nil),
            ("https://friendcal.app/f/\(String(token.dropLast()))", nil),
            ("https://friendcal.app/f/\(token)A", nil),
            ("friendcal://friend/\(String(token.dropLast()))+", nil),
            ("friendcal://friend/\(String(token.dropLast()))%20", nil),
        ]
        for (text, expected) in rows {
            XCTAssertEqual(URL(string: text).flatMap(DeepLink.parse), expected, text)
        }
    }

    /// protects=a friend link is not a plan link: the accessors that used to be total answer nil for
    /// the other kind; fails_when=proposalID or title returns something for a friend link.
    func testAccessorsAreNotTotal() {
        XCTAssertNil(DeepLink.friend(token, name: "Sam").proposalID)
        XCTAssertNil(DeepLink.friend(token, name: "Sam").title)
        XCTAssertEqual(DeepLink.friend(token, name: "Sam").friendToken, token)
        XCTAssertEqual(DeepLink.friend(token, name: "Sam").friendName, "Sam")
        XCTAssertNil(DeepLink.proposal(planID).friendToken)
        XCTAssertEqual(DeepLink.proposal(planID, title: "Brunch").proposalID, planID)
    }

    /// protects=the 40-character cap on a name hint and the 80 on a plan title are separate, through
    /// the one sanitizer; fails_when=the cap parameter is ignored or the two share a limit.
    func testNameHintCapIsFortyAndTitleCapStaysEighty() {
        let long = String(repeating: "b", count: 100)
        XCTAssertEqual(DeepLink.sanitizedTitle(long, cap: DeepLink.maxNameLength)?.count, 40)
        XCTAssertEqual(DeepLink.sanitizedTitle(long)?.count, 80)
        XCTAssertEqual(DeepLink.parse(URL(string: "friendcal://friend/\(token)?n=\(long)")!)?.friendName?.count, 40)
        XCTAssertEqual(DeepLink.parse(URL(string: "friendcal://proposal/\(planID.uuidString)?t=\(long)")!)?.title?.count, 80)
    }

    /// protects=a hint carrying markup or a bidi override arrives as plain text with the override gone,
    /// and a hint that cleans to nothing is no hint; fails_when=the friend path skips sanitizing.
    func testNameHintIsSanitizedAtTheBoundary() {
        let hostile = "\u{202E}<img src=x onerror=alert(1)>"
        let link = DeepLink.parse(URL(string: "friendcal://friend/\(token)")!.appending(queryItems: [URLQueryItem(name: "n", value: hostile)]))
        XCTAssertEqual(link?.friendName, "<img src=x onerror=alert(1)>")
        XCTAssertNil(DeepLink.parse(URL(string: "friendcal://friend/\(token)?n=%E2%80%AE")!)?.friendName)
    }

    /// protects=what the app shares parses back to the same link in both forms, the custom scheme is
    /// shared until the site ships, and one constant flips it; fails_when=url, webURL and parse disagree.
    func testShareFormsRoundTrip() {
        let link = DeepLink.friend(token, name: "Sam")
        XCTAssertEqual(link.url.absoluteString, "friendcal://friend/\(token)?n=Sam")
        XCTAssertEqual(link.webURL.absoluteString, "https://friendcal.app/f/\(token)?n=Sam")
        XCTAssertEqual(DeepLink.parse(link.url), link)
        XCTAssertEqual(DeepLink.parse(link.webURL), link)
        XCTAssertEqual(link.shareURL, DeepLink.useWebLinks ? link.webURL : link.url)
        XCTAssertTrue(DeepLink.useWebLinks, "shared links are https now that friendcal.app serves them")
        XCTAssertEqual(link.shareURL.absoluteString, "https://friendcal.app/f/\(token)?n=Sam")
        let plan = DeepLink.proposal(planID, title: "Brunch")
        XCTAssertEqual(plan.webURL.absoluteString, "https://friendcal.app/p/\(planID.uuidString.lowercased())?t=Brunch")
        XCTAssertEqual(DeepLink.parse(plan.webURL), plan)
        XCTAssertEqual(DeepLink.friend(token).url.absoluteString, "friendcal://friend/\(token)", "no hint, no query")
    }

    func testFriendTokenRules() {
        XCTAssertTrue(FriendToken.isValid(token))
        XCTAssertTrue(FriendToken.isValid(String(repeating: "_", count: 22)))
        XCTAssertFalse(FriendToken.isValid(""))
        XCTAssertFalse(FriendToken.isValid(String(repeating: "a", count: 21)))
        XCTAssertFalse(FriendToken.isValid(String(repeating: "a", count: 23)))
        XCTAssertFalse(FriendToken.isValid(String(repeating: "é", count: 11)), "22 bytes of non-ASCII is not 22 characters of the alphabet")
        XCTAssertEqual(FriendToken.display(token), "friendcal.app/f/\(token)")
    }

    /// protects=the share message reads as the spec says, with the link on its own line, and never
    /// prints a placeholder as if it were a name; fails_when=the wording drifts.
    func testShareText() {
        let url = DeepLink.friend(token).url
        XCTAssertEqual(ShareText.friendLink(name: "Sam", url: url), "Sam wants to connect with you on FriendCal.\n\(url.absoluteString)")
        XCTAssertEqual(ShareText.friendLink(name: "  ", url: url), "A friend wants to connect with you on FriendCal.\n\(url.absoluteString)")
        XCTAssertEqual(ShareText.friendLink(name: Friend.placeholderName, url: url), "A friend wants to connect with you on FriendCal.\n\(url.absoluteString)")
    }
}

final class FriendRosterTests: XCTestCase {
    private func friend(_ n: Int, _ name: String = "F") -> Friend { Friend(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!, name: "\(name)\(n)") }

    /// protects=the first load for an account is silent, so a reinstall does not announce everyone,
    /// and a later friend is an arrival; fails_when=the first load announces, or a later one does not.
    func testFirstLoadIsSilent() {
        var roster = FriendRoster()
        let gen = roster.beginRefresh()
        XCTAssertTrue(roster.apply([friend(1), friend(2)], startedAt: gen))
        XCTAssertTrue(roster.arrivals.isEmpty)
        XCTAssertTrue(roster.hasLoaded)
        XCTAssertTrue(roster.apply([friend(3), friend(1), friend(2)], startedAt: roster.beginRefresh()))
        XCTAssertEqual(roster.arrivals.map(\.id), [friend(3).id])
    }

    /// protects="never loaded" differs from "loaded and empty": a new person's first friend is announced;
    /// fails_when=an empty first load leaves knownIDs nil, so the first friend is swallowed.
    func testFirstFriendOfANewPersonIsAnnounced() {
        var roster = FriendRoster()
        roster.apply([], startedAt: roster.beginRefresh())
        XCTAssertEqual(roster.knownIDs, [])
        roster.apply([friend(1)], startedAt: roster.beginRefresh())
        XCTAssertEqual(roster.arrivals.count, 1)
    }

    /// protects=several arrivals at once are all held and announced once, and announcing is final;
    /// fails_when=takeArrivals leaves them new, or returns only one.
    func testSeveralArrivalsAreHeldThenTakenOnce() {
        var roster = FriendRoster(friends: [], knownIDs: [], hasLoaded: true)
        roster.apply([friend(3), friend(2), friend(1)], startedAt: roster.beginRefresh())
        XCTAssertEqual(roster.arrivals.count, 3)
        XCTAssertEqual(roster.arrivals.count, 3, "held until taken: reading them does not consume them")
        XCTAssertEqual(roster.takeArrivals().count, 3)
        XCTAssertTrue(roster.arrivals.isEmpty)
        XCTAssertTrue(roster.takeArrivals().isEmpty)
        XCTAssertEqual(roster.knownIDs?.count, 3)
    }

    /// protects=an arrival stays an arrival across a relaunch until it is shown: the saved set is
    /// restored and the friend is still not in it; fails_when=apply adds new ids to the saved set.
    func testArrivalSurvivesARelaunchUntilShown() {
        var first = FriendRoster()
        first.apply([friend(1)], startedAt: first.beginRefresh())
        let saved = first.knownIDs
        var relaunched = FriendRoster(knownIDs: saved)
        relaunched.apply([friend(2), friend(1)], startedAt: relaunched.beginRefresh())
        XCTAssertEqual(relaunched.arrivals.map(\.id), [friend(2).id])
        var again = FriendRoster(knownIDs: relaunched.knownIDs)
        again.apply([friend(2), friend(1)], startedAt: again.beginRefresh())
        XCTAssertEqual(again.arrivals.map(\.id), [friend(2).id], "not taken, so still new")
    }

    /// protects=an id that leaves the roster leaves the saved set, so a friend who is removed and
    /// comes back is announced again; fails_when=knownIDs only grows.
    func testRemovedIDLeavesTheSavedSet() {
        var roster = FriendRoster()
        roster.apply([friend(1), friend(2)], startedAt: roster.beginRefresh())
        roster.apply([friend(1)], startedAt: roster.beginRefresh())
        XCTAssertEqual(roster.knownIDs, [friend(1).id])
        roster.apply([friend(2), friend(1)], startedAt: roster.beginRefresh())
        XCTAssertEqual(roster.arrivals.map(\.id), [friend(2).id])
    }

    /// protects=a refresh that began before a local accept or remove is discarded and changes nothing;
    /// fails_when=a stale read overwrites the friend a Connect just made, or resurrects a removed one.
    func testStaleRefreshIsDiscarded() {
        var roster = FriendRoster()
        roster.apply([friend(1)], startedAt: roster.beginRefresh())
        let slow = roster.beginRefresh()
        roster.insertLocally(friend(2))
        XCTAssertFalse(roster.apply([friend(1)], startedAt: slow))
        XCTAssertEqual(roster.friends.map(\.id), [friend(2).id, friend(1).id])
        let slowRemove = roster.beginRefresh()
        roster.removeLocally(friend(1).id)
        XCTAssertFalse(roster.apply([friend(2), friend(1)], startedAt: slowRemove))
        XCTAssertEqual(roster.friends.map(\.id), [friend(2).id])
        XCTAssertTrue(roster.apply([friend(2)], startedAt: roster.beginRefresh()))
    }

    /// protects=the person who taps Connect is never told about the friend they just made: the inviter
    /// joins the saved set before the call; fails_when=insertLocally or markKnown leaves them an arrival.
    func testTheRecipientIsNotAnnouncedTheirOwnConnection() {
        var roster = FriendRoster()
        roster.apply([], startedAt: roster.beginRefresh())
        roster.markKnown(friend(1).id)
        roster.noteLocalChange()
        roster.apply([friend(1)], startedAt: roster.beginRefresh())
        XCTAssertTrue(roster.arrivals.isEmpty)
        var other = FriendRoster()
        other.apply([], startedAt: other.beginRefresh())
        other.insertLocally(friend(9))
        XCTAssertTrue(other.arrivals.isEmpty)
    }

    /// protects=rows never jump: friends already shown keep their place and new ones go first;
    /// fails_when=apply re-sorts the list.
    func testExistingFriendsKeepTheirOrder() {
        var roster = FriendRoster()
        roster.apply([friend(1), friend(2), friend(3)], startedAt: roster.beginRefresh())
        roster.apply([friend(4), friend(3), friend(2), friend(1)], startedAt: roster.beginRefresh())
        XCTAssertEqual(roster.friends.map(\.id), [4, 1, 2, 3].map { friend($0).id })
    }

    /// protects=a failed refresh is simply not applied: the roster, the loaded flag and the saved set
    /// stay as they were (the caller never calls apply); fails_when=none -- documents the contract.
    func testFailedRefreshLeavesTheRosterAlone() {
        var roster = FriendRoster()
        roster.apply([friend(1)], startedAt: roster.beginRefresh())
        let before = roster
        _ = roster.beginRefresh()   // a refresh starts and throws: nothing else happens
        XCTAssertEqual(roster, before)
    }

    func testArrivalText() {
        XCTAssertNil(FriendRoster.arrivalText([]))
        XCTAssertEqual(FriendRoster.arrivalText([friend(1, "Jess")]), "You and Jess1 are connected")
        XCTAssertEqual(FriendRoster.arrivalText([friend(1, "Jess"), friend(2)]), "Jess1 and 1 other are connected")
        XCTAssertEqual(FriendRoster.arrivalText([friend(1, "Jess"), friend(2), friend(3)]), "Jess1 and 2 others are connected")
    }

    /// protects=the wheel draws plan members when there are any and friends when there are none, with
    /// the same 10-face cap and overflow, and the active face always keeps a seat;
    /// fails_when=the source flips, the cap moves, or the pinned face is pushed into the overflow.
    func testWheelSourceAndFaces() {
        XCTAssertEqual(FriendRoster.wheelSource(planMemberCount: 3), .planMembers)
        XCTAssertEqual(FriendRoster.wheelSource(planMemberCount: 0), .friends)
        let ten = (1...10).map { friend($0) }
        XCTAssertEqual(FriendRoster.wheelFaces(ten).faces.count, 10)
        XCTAssertEqual(FriendRoster.wheelFaces(ten).overflow, 0)
        let twelve = (1...12).map { friend($0) }
        let split = FriendRoster.wheelFaces(twelve)
        XCTAssertEqual(split.faces.count, 9)
        XCTAssertEqual(split.overflow, 3)
        XCTAssertTrue(FriendRoster.wheelFaces(twelve, pinned: friend(12).id).faces.contains { $0.id == friend(12).id })
        XCTAssertEqual(FriendRoster.wheelFaces([Friend]()).faces.count, 0)
    }

    func testBlankNameBecomesThePlaceholder() {
        XCTAssertEqual(Friend(id: UUID(), name: "  ").name, "Friend")
        XCTAssertEqual(Friend(id: UUID(), name: " Sam ").name, "Sam")
    }
}

final class LinkRouterStateTests: XCTestCase {
    private let token = "AbCdEfGhIjKlMnOpQr_-12"
    private let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000900")!
    private var friendURL: URL { URL(string: "friendcal://friend/\(token)?n=Sam")! }
    private var planURL: URL { URL(string: "friendcal://proposal/\(planID.uuidString)")! }

    /// protects=a plan link opened while signed out is kept (the regression the old replay code never
    /// met: nothing stored it) and finishing it clears it; fails_when=open does not store, or finish keeps it.
    func testALinkIsKeptUntilItIsAnswered() {
        var state = LinkRouterState()
        guard case .pending(let generation) = state.open(planURL) else { return XCTFail("a plan link is pending") }
        XCTAssertEqual(state.pending, .proposal(planID))
        XCTAssertTrue(state.finish(generation: generation))
        XCTAssertNil(state.pending)
    }

    /// protects=one pending link at a time, the newest wins, and a slow answer for an older link
    /// cannot clear the newer one; fails_when=finish ignores the generation.
    func testNewerLinkReplacesOlderAndOldFinishDoesNotClearIt() {
        var state = LinkRouterState()
        guard case .pending(let first) = state.open(planURL), case .pending(let second) = state.open(friendURL) else { return XCTFail() }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(state.pending, .friend(token, name: "Sam"))
        XCTAssertFalse(state.finish(generation: first))
        XCTAssertEqual(state.pending, .friend(token, name: "Sam"))
        XCTAssertTrue(state.finish(generation: second))
    }

    /// protects=junk opens nothing and does not disturb a pending link; fails_when=an invalid URL clears or replaces it.
    func testInvalidLinkChangesNothing() {
        var state = LinkRouterState()
        state.open(friendURL)
        XCTAssertEqual(state.open(URL(string: "https://example.com/x")!), .invalid)
        XCTAssertEqual(state.pending, .friend(token, name: "Sam"))
    }

    /// protects=Not now, sign-out and deletion leave nothing pending, and an operation still in flight
    /// for the cleared link cannot match a later one; fails_when=clear does not bump the generation.
    func testClearLeavesNothingAndInvalidatesInFlightWork() {
        var state = LinkRouterState()
        guard case .pending(let old) = state.open(friendURL) else { return XCTFail() }
        state.clear()
        XCTAssertNil(state.pending)
        XCTAssertNil(state.storedURL)
        state.open(planURL)
        XCTAssertFalse(state.finish(generation: old))
        XCTAssertNotNil(state.pending)
    }

    /// protects=the pending link survives a relaunch through its stored form, and a stored value that
    /// no longer parses is dropped; fails_when=storedURL loses the token or name, or restoring trusts junk.
    func testSurvivesARelaunch() {
        var state = LinkRouterState()
        state.open(friendURL)
        let restored = LinkRouterState(restoring: state.storedURL)
        XCTAssertEqual(restored.pending, .friend(token, name: "Sam"))
        XCTAssertNil(LinkRouterState(restoring: URL(string: "friendcal://friend/short")!).pending)
        XCTAssertNil(LinkRouterState(restoring: nil).pending)
    }
}

@MainActor
final class InMemoryFriendStoreTests: XCTestCase {
    private let sam = User(id: UUID(), displayName: "Sam")
    private let maya = User(id: UUID(), displayName: "Maya")
    private let leo = User(id: UUID(), displayName: "Leo")
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var store: InMemoryProposalStore!

    override func setUp() async throws {
        store = InMemoryProposalStore(users: [sam, maya, leo], currentUserID: sam.id, now: { [unowned self] in self.clock })
    }

    private func become(_ user: User) {
        store.seed(users: store.users, proposals: store.proposals, slots: store.slots, busyBlocks: store.busyBlocks,
                   places: store.places, votes: store.votes, currentUserID: user.id)
    }

    private func hint(_ work: () async throws -> Void) async -> String? {
        do { try await work(); return "no error" } catch let ProposalStoreError.server(_, _, hint) { return hint } catch { return "\(error)" }
    }

    /// protects=a link is minted once, is 22 characters of the alphabet, is the same on every read and
    /// differs per person; fails_when=a second read mints, or the token breaks FriendToken.
    func testLinkIsMintedOnce() async throws {
        let token = try await store.friendLink()
        XCTAssertTrue(FriendToken.isValid(token))
        let again = try await store.friendLink()
        XCTAssertEqual(again, token)
        XCTAssertEqual(store.friendLinks[sam.id]?.mintCount, 1)
        become(maya)
        let other = try await store.friendLink()
        XCTAssertNotEqual(other, token)
    }

    /// protects=a reset kills the old link for everyone, keeps friendships and zeroes the cap count;
    /// fails_when=the old token still answers, or a reset ends a friendship.
    func testResetKillsTheOldLinkAndKeepsFriends() async throws {
        let old = try await store.friendLink()
        become(maya)
        _ = try await store.acceptFriendLink(token: old)
        become(sam)
        let new = try await store.resetFriendLink()
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(store.friendLinks[sam.id]?.tokenAccepts, 0)
        XCTAssertEqual(store.friendLinks[sam.id]?.mintCount, 2)
        become(leo)
        let oldAnswer = try await store.previewFriendLink(token: old)
        XCTAssertEqual(oldAnswer, .dead)
        let acceptOld = try await store.acceptFriendLink(token: old)
        XCTAssertEqual(acceptOld, .dead)
        let friends = try await store.friends()
        XCTAssertTrue(friends.isEmpty)
        become(sam)
        let samFriends = try await store.friends()
        XCTAssertEqual(samFriends.map(\.id), [maya.id], "a reset removed nobody")
    }

    /// protects=preview and accept give the four answers, preview changes nothing, and accept connects
    /// once with one push; fails_when=preview writes, a repeat accept writes again, or the push is wrong.
    func testPreviewAndAcceptAnswers() async throws {
        let token = try await store.friendLink()
        let own = try await store.previewFriendLink(token: token)
        XCTAssertEqual(own, .own)
        become(maya)
        let preview = try await store.previewFriendLink(token: token)
        XCTAssertEqual(preview.status, .valid)
        XCTAssertEqual(preview.person, Friend(id: sam.id, name: "Sam"))
        XCTAssertTrue(store.friendships.isEmpty, "preview connects nobody")
        XCTAssertTrue(store.outbox.isEmpty)
        let accepted = try await store.acceptFriendLink(token: token)
        XCTAssertEqual(accepted.status, .valid)
        XCTAssertEqual(store.friendships.count, 1)
        XCTAssertEqual(store.outbox.count, 1)
        XCTAssertEqual(store.outbox[0].kind, .friendJoined)
        XCTAssertEqual(store.outbox[0].recipientID, sam.id)
        XCTAssertEqual(store.outbox[0].title, "Maya connected with you")
        XCTAssertEqual(store.outbox[0].body, "You two are connected.")
        XCTAssertEqual(store.outbox[0].expiresAt, clock.addingTimeInterval(24 * 3600))
        XCTAssertNil(store.outbox[0].route, "the app does not route friend_joined yet")
        let repeated = try await store.acceptFriendLink(token: token)
        XCTAssertEqual(repeated.status, .already, "a retry after a lost reply is already, which the screen counts as success")
        XCTAssertEqual(store.friendships.count, 1)
        XCTAssertEqual(store.outbox.count, 1)
        XCTAssertEqual(store.friendLinks[sam.id]?.tokenAccepts, 1)
        become(sam)
        let selfAccept = try await store.acceptFriendLink(token: token)
        XCTAssertEqual(selfAccept, .own)
    }

    /// protects=two people accepting each other's links end with one friendship and one push;
    /// fails_when=the second accept connects again.
    func testMutualAcceptIsOneFriendship() async throws {
        let samToken = try await store.friendLink()
        become(maya)
        let mayaToken = try await store.friendLink()
        _ = try await store.acceptFriendLink(token: samToken)
        become(sam)
        let second = try await store.acceptFriendLink(token: mayaToken)
        XCTAssertEqual(second.status, .already)
        XCTAssertEqual(store.friendships.count, 1)
        XCTAssertEqual(store.outbox.count, 1)
    }

    /// protects=every cause of a dead link answers the same dead from preview and accept: unknown,
    /// malformed, reset, a deleted owner, a caller the owner removed, and the 50-accept cap;
    /// fails_when=any cause answers something else, or preview and accept disagree.
    func testEveryDeadCause() async throws {
        let token = try await store.friendLink()
        become(maya)
        for bad in ["", "short", String(repeating: "A", count: 22), String(repeating: "+", count: 22)] {
            let p = try await store.previewFriendLink(token: bad)
            let a = try await store.acceptFriendLink(token: bad)
            XCTAssertEqual(p, .dead, bad)
            XCTAssertEqual(a, .dead, bad)
        }
        // the cap: 50 accepts work, the 51st is dead, a reset starts over.
        become(sam)
        var record = store.friendLinks[sam.id]!
        record.tokenAccepts = InMemoryProposalStore.friendLinkCap - 1
        store.setFriendLinkRecord(record, for: sam.id)
        become(maya)
        let fiftieth = try await store.acceptFriendLink(token: token)
        XCTAssertEqual(fiftieth.status, .valid)
        become(leo)
        let previewCap = try await store.previewFriendLink(token: token)
        let acceptCap = try await store.acceptFriendLink(token: token)
        XCTAssertEqual(previewCap, .dead)
        XCTAssertEqual(acceptCap, .dead)
        become(sam)
        let fresh = try await store.resetFriendLink()
        become(leo)
        let afterReset = try await store.acceptFriendLink(token: fresh)
        XCTAssertEqual(afterReset.status, .valid)
        // a deleted owner
        become(sam)
        _ = try await store.deleteAccount()
        become(maya)
        let deadOwner = try await store.previewFriendLink(token: fresh)
        XCTAssertEqual(deadOwner, .dead)
    }

    /// protects=removal: both sides lose the friendship, one record is written only when a friendship
    /// was deleted, the removed person reads the remover's links as dead before and after a reset, and
    /// the remover reconnects by accepting the other person's link; fails_when=any of those drift.
    func testRemoveAndReconnect() async throws {
        let samToken = try await store.friendLink()
        become(maya)
        _ = try await store.acceptFriendLink(token: samToken)
        let mayaToken = try await store.friendLink()
        become(sam)
        try await store.removeFriend(leo.id)
        XCTAssertTrue(store.friendRemovals.isEmpty, "removing a non-friend writes nothing")
        try await store.removeFriend(maya.id)
        try await store.removeFriend(maya.id)
        XCTAssertEqual(store.friendRemovals.count, 1, "idempotent")
        XCTAssertTrue(store.friendships.isEmpty)
        become(maya)
        let before = try await store.previewFriendLink(token: samToken)
        XCTAssertEqual(before, .dead)
        become(sam)
        let newToken = try await store.resetFriendLink()
        become(maya)
        let after = try await store.acceptFriendLink(token: newToken)
        XCTAssertEqual(after, .dead, "dead before and after a reset")
        XCTAssertTrue(store.friendships.isEmpty)
        become(sam)
        let reconnect = try await store.acceptFriendLink(token: mayaToken)
        XCTAssertEqual(reconnect.status, .valid)
        XCTAssertEqual(store.friendships.count, 1)
        XCTAssertTrue(store.friendRemovals.isEmpty, "accepting their link clears the record")
    }

    /// protects=friends() lists the caller's friends newest first, never a deleted account, and a
    /// removed friend leaves it; fails_when=a tombstone is listed or the order is not newest first.
    func testFriendsListing() async throws {
        let samToken = try await store.friendLink()
        become(maya)
        _ = try await store.acceptFriendLink(token: samToken)
        clock = clock.addingTimeInterval(60)
        become(leo)
        _ = try await store.acceptFriendLink(token: samToken)
        become(sam)
        let list = try await store.friends()
        XCTAssertEqual(list.map(\.name), ["Leo", "Maya"])
        XCTAssertNotNil(list[0].connectedAt)
        become(leo)
        _ = try await store.deleteAccount()
        become(sam)
        let afterDelete = try await store.friends()
        XCTAssertEqual(afterDelete.map(\.name), ["Maya"])
        XCTAssertFalse(store.friendships.keys.contains { $0.other(than: leo.id) != nil }, "a deleted account is nobody's friend")
        XCTAssertNil(store.friendLinks[leo.id])
    }

    /// protects=a friendship lets people poke with no shared plan, a removal ends that, and the
    /// refusal reads "friends"; fails_when=the gate ignores friendships or survives a removal.
    func testFriendsCanPokeUntilRemoved() async throws {
        let stranger = await hint { _ = try await store.sendPoke(to: maya.id, about: nil) }
        XCTAssertEqual(stranger, "FC_NOT_FRIEND")
        let token = try await store.friendLink()
        become(maya)
        _ = try await store.acceptFriendLink(token: token)
        let poked = try await store.sendPoke(to: sam.id, about: nil)
        XCTAssertTrue(poked.isNew)
        become(sam)
        try await store.removeFriend(maya.id)
        let after = await hint { _ = try await store.sendPoke(to: maya.id, about: nil) }
        XCTAssertEqual(after, "FC_NOT_FRIEND")
    }

    /// protects=the launch-argument scenarios answer for any token, accept really connects, and a
    /// second accept is already; fails_when=a scenario answers by the real rules or does not connect.
    func testScenarioOverride() async throws {
        become(maya)
        for (scenario, expected) in [(InMemoryProposalStore.FriendLinkScenario.dead, FriendLinkAnswer.Status.dead),
                                     (.own, .own), (.already, .already), (.valid, .valid)] {
            store.friendLinkScenario = scenario
            let p = try await store.previewFriendLink(token: "whatever")
            XCTAssertEqual(p.status, expected, "\(scenario)")
        }
        store.friendLinkScenario = .valid
        let preview = try await store.previewFriendLink(token: "x")
        XCTAssertEqual(preview.person?.name, "Sam")
        let first = try await store.acceptFriendLink(token: "x")
        XCTAssertEqual(first.status, .valid)
        XCTAssertEqual(store.friendships.count, 1)
        let second = try await store.acceptFriendLink(token: "x")
        XCTAssertEqual(second.status, .already)
    }

    /// protects=a failed operation changes nothing and the failure hook reaches every new operation,
    /// and a reset that is told to fail leaves the old token live; fails_when=a failure is half applied.
    func testFailNextReachesEveryOperationAndAppliesNothing() async throws {
        let token = try await store.friendLink()
        store.failNext[.resetFriendLink] = ProposalStoreError.network("down")
        do { _ = try await store.resetFriendLink(); XCTFail("should throw") } catch {}
        let same = try await store.friendLink()
        XCTAssertEqual(same, token, "the old link is still the link")
        become(maya)
        store.failNext[.acceptFriendLink] = ProposalStoreError.network("down")
        do { _ = try await store.acceptFriendLink(token: token); XCTFail("should throw") } catch {}
        XCTAssertTrue(store.friendships.isEmpty)
        store.failNext[.friends] = ProposalStoreError.network("down")
        do { _ = try await store.friends(); XCTFail("should throw") } catch {}
        store.failNext[.removeFriend] = ProposalStoreError.network("down")
        do { try await store.removeFriend(sam.id); XCTFail("should throw") } catch {}
        store.failNext[.friendLink] = ProposalStoreError.network("down")
        do { _ = try await store.friendLink(); XCTFail("should throw") } catch {}
        store.failNext[.previewFriendLink] = ProposalStoreError.network("down")
        do { _ = try await store.previewFriendLink(token: token); XCTFail("should throw") } catch {}
    }

    /// protects=one person's link and friendships are not another's after a switch of account;
    /// fails_when=friend state is read without the identity.
    func testASecondAccountSeesNeitherOthersLinkNorFriends() async throws {
        let samToken = try await store.friendLink()
        become(maya)
        _ = try await store.acceptFriendLink(token: samToken)
        become(leo)
        let none = try await store.friends()
        XCTAssertTrue(none.isEmpty)
        let leoToken = try await store.friendLink()
        XCTAssertNotEqual(leoToken, samToken)
        XCTAssertNil(store.friendLinks[leo.id].flatMap { $0.token == samToken ? $0 : nil })
    }

    /// protects=a signed-out caller and a deleted one are refused with the same hints the server gives;
    /// fails_when=a deleted account can mint or accept.
    func testSignedOutAndDeletedAreRefused() async throws {
        let token = try await store.friendLink()
        await store.signOut()
        let signedOut = await hint { _ = try await store.friendLink() }
        XCTAssertEqual(signedOut, "\(ProposalStoreError.notSignedIn)")
        become(maya)
        _ = try await store.deleteAccount()
        store.seed(users: store.users, proposals: [], slots: [], currentUserID: maya.id)
        let deleted = await hint { _ = try await store.acceptFriendLink(token: token) }
        XCTAssertEqual(deleted, "FC_ACCOUNT_DELETED")
    }
}

final class FriendErrorCopyTests: XCTestCase {
    /// protects=each new action reads its own sentence and never the lock wording, and the refusals
    /// friends.sql raises map to sentences; fails_when=an action falls back to "Only the host can lock".
    func testEachNewActionHasItsOwnSentence() {
        func say(_ action: UserFacingError.Action, code: String = "P0002", hint: String? = nil) -> String {
            UserFacingError.map(ProposalStoreError.server(code: code, message: "raw", hint: hint), action: action).message
        }
        XCTAssertEqual(say(.friendLink, code: "55000"), "Couldn't get your link")
        XCTAssertEqual(say(.previewFriend, code: "42501"), "Couldn't check this link. Try again.")
        XCTAssertEqual(say(.acceptFriend, code: "55000"), "Couldn't connect. Try again.")
        XCTAssertEqual(say(.loadFriends, code: "22023"), "Couldn't load your friends. Try again.")
        XCTAssertEqual(say(.removeFriend, code: "42501"), "Couldn't remove that friend. Try again.")
        XCTAssertEqual(say(.acceptFriend, code: "42501", hint: "FC_ACCOUNT_DELETED"), "This account has been deleted.")
        XCTAssertEqual(say(.acceptFriend, code: "42501", hint: "FC_NOT_SIGNED_IN"), "Sign in to continue.")
        XCTAssertEqual(say(.poke, hint: "FC_NOT_FRIEND"), "You can only poke friends.")
        let network = UserFacingError.map(ProposalStoreError.network("down"), action: .acceptFriend)
        XCTAssertEqual(network.message, "Couldn't connect. Try again.")
    }
}

@MainActor
final class FriendAcceptFlowTests: XCTestCase {
    private let sam = User(id: UUID(), displayName: "Sam")
    private let maya = User(id: UUID(), displayName: "Maya")
    private var store: InMemoryProposalStore!
    private var token = ""

    override func setUp() async throws {
        store = InMemoryProposalStore(users: [sam, maya], currentUserID: sam.id)
        token = try await store.friendLink()
        store.seed(users: store.users, proposals: [], slots: [], currentUserID: maya.id)
    }

    /// protects=checking calls only preview, and a valid link shows the inviter the SERVER named;
    /// fails_when=the check connects anyone, or the name comes from anywhere but the answer.
    func testCheckPreviewsAndChangesNothing() async {
        let flow = FriendAcceptFlow(store: store, token: token)
        XCTAssertEqual(flow.phase, .checking)
        await flow.check()
        XCTAssertEqual(flow.phase, .ready(Friend(id: sam.id, name: "Sam")))
        XCTAssertTrue(store.friendships.isEmpty)
    }

    /// protects=connect makes the friendship, marks the inviter known BEFORE the call, and a double tap
    /// is one call; fails_when=willConnect runs after the accept, or two taps connect twice.
    func testConnectMarksKnownFirstAndIgnoresADoubleTap() async {
        var marked: [UUID] = []
        var friendsAtMark = -1
        let flow = FriendAcceptFlow(store: store, token: token) { id in marked.append(id); friendsAtMark = self.store.friendships.count }
        await flow.check()
        async let first = flow.connect()
        async let second = flow.connect()
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1, "one of the two taps made the connection")
        XCTAssertEqual(marked, [sam.id])
        XCTAssertEqual(friendsAtMark, 0, "marked before the server was called")
        XCTAssertEqual(store.friendships.count, 1)
        XCTAssertEqual(store.outbox.count, 1)
    }

    /// protects=a failed connect keeps the link and offers Retry, and a retry answered `already` counts
    /// as success; fails_when=the failure is terminal or a repeat is shown as an error.
    func testFailedConnectRetriesAndAlreadyCountsAsSuccess() async {
        let flow = FriendAcceptFlow(store: store, token: token)
        await flow.check()
        store.failNext[.acceptFriendLink] = ProposalStoreError.network("down")
        let failed = await flow.connect()
        XCTAssertNil(failed)
        guard case .connectFailed(let friend, let error) = flow.phase else { return XCTFail("\(flow.phase)") }
        XCTAssertEqual(friend.name, "Sam")
        XCTAssertEqual(error.message, "Couldn't connect. Try again.")
        XCTAssertTrue(store.friendships.isEmpty)
        // the first reply was lost on the way back: the server DID connect
        store.befriend([sam.id], with: maya.id)
        let retried = await flow.connect()
        XCTAssertEqual(retried?.id, sam.id, "already counts as connected")
    }

    /// protects=a failed check keeps the link and Retry checks again; fails_when=the failure is terminal.
    func testFailedCheckRetries() async {
        let flow = FriendAcceptFlow(store: store, token: token)
        store.failNext[.previewFriendLink] = ProposalStoreError.network("down")
        await flow.check()
        guard case .checkFailed(let error) = flow.phase else { return XCTFail("\(flow.phase)") }
        XCTAssertEqual(error.message, "Couldn't check this link. Try again.")
        await flow.check()
        XCTAssertEqual(flow.phase, .ready(Friend(id: sam.id, name: "Sam")))
    }

    /// protects=dead, own and already each reach their own state, and a link that dies between the
    /// preview and the tap lands on dead; fails_when=any state is mislabeled or connect proceeds.
    func testDeadOwnAlreadyAndDyingBetweenPreviewAndTap() async throws {
        let dead = FriendAcceptFlow(store: store, token: String(repeating: "Z", count: 22))
        await dead.check()
        XCTAssertEqual(dead.phase, .dead)
        let connectDead = await dead.connect()
        XCTAssertNil(connectDead, "nothing to connect")

        store.befriend([sam.id], with: maya.id)
        let already = FriendAcceptFlow(store: store, token: token)
        await already.check()
        XCTAssertEqual(already.phase, .already(Friend(id: sam.id, name: "Sam")))

        store.seed(users: store.users, proposals: [], slots: [], currentUserID: sam.id)
        let own = FriendAcceptFlow(store: store, token: token)
        await own.check()
        XCTAssertEqual(own.phase, .own)

        // preview said valid; the owner then reset: Connect answers dead.
        let stranger = User(id: UUID(), displayName: "Leo")
        store.seed(users: store.users + [stranger], proposals: [], slots: [], currentUserID: stranger.id)
        let dying = FriendAcceptFlow(store: store, token: token)
        await dying.check()
        store.seed(users: store.users, proposals: [], slots: [], currentUserID: sam.id)
        _ = try await store.resetFriendLink()
        store.seed(users: store.users, proposals: [], slots: [], currentUserID: stranger.id)
        let result = await dying.connect()
        XCTAssertNil(result)
        XCTAssertEqual(dying.phase, .dead)
    }
}
