import XCTest
@testable import FriendCalCore

/// The poke lifecycle, its copy, the Pokes tab's sections, the Tag along rules and the push route,
/// as pure values. No store: `InMemorySocialStoreTests` covers the rules that need one.
final class PokeTests: XCTestCase {
    private let me = UUID(), arlo = UUID(), maya = UUID(), leo = UUID()
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    // MARK: Lifecycle

    /// protects=a poke is live for exactly one hour and the boundary instant is already expired, the
    /// same edge AvailabilitySlot uses; fails_when=the lifetime changes or `==` counts as live;
    /// no_claim=the server's clock (social_test.sql asserts its hour).
    func testAPokeIsLiveForOneHour() {
        let poke = Poke(fromID: me, toID: arlo, createdAt: now)
        XCTAssertEqual(poke.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(poke.state(at: now), .live(remaining: 3600))
        XCTAssertEqual(poke.state(at: now.addingTimeInterval(3599)), .live(remaining: 1))
        XCTAssertEqual(poke.state(at: now.addingTimeInterval(3600)), .expired)
        XCTAssertFalse(poke.isLive(at: now.addingTimeInterval(3600)))
    }

    /// protects=acknowledged outranks expired, so a poke seen at minute 59 still reads seen after the
    /// hour; fails_when=state() tests the expiry first; no_claim=who acknowledged.
    func testAcknowledgedWinsOverExpired() {
        let poke = Poke(fromID: me, toID: arlo, createdAt: ago(120), acknowledgedAt: ago(61), ackVia: .push)
        XCTAssertEqual(poke.state(at: now), .acknowledged(at: ago(61), via: .push))
        XCTAssertFalse(poke.isLive(at: now))
    }

    /// protects=the fuse runs 1 -> 0 across the hour and is 0 once the poke ends either way;
    /// fails_when=the bar shows time left on a poke that is over; no_claim=its drawing.
    func testFuseDrainsAcrossTheHour() {
        XCTAssertEqual(Poke(fromID: me, toID: arlo, createdAt: now).fuse(at: now), 1)
        XCTAssertEqual(Poke(fromID: me, toID: arlo, createdAt: ago(30)).fuse(at: now), 0.5, accuracy: 0.0001)
        XCTAssertEqual(Poke(fromID: me, toID: arlo, createdAt: ago(90)).fuse(at: now), 0)
        XCTAssertEqual(Poke(fromID: me, toID: arlo, createdAt: ago(10), acknowledgedAt: ago(5), ackVia: .app).fuse(at: now), 0)
    }

    // MARK: Copy

    /// protects=the toast is one sentence wherever a poke is sent from: a new poke says it fades in an
    /// hour, a repeat says how long the first has left and never claims to have sent another;
    /// fails_when=a repeat reads like a second poke; no_claim=the toast's styling.
    func testSentToastTellsANewPokeFromARepeat() {
        let fresh = PokeReceipt(poke: Poke(fromID: me, toID: arlo, createdAt: now), isNew: true)
        XCTAssertEqual(PokeText.sent(name: "Arlo", receipt: fresh, now: now), "Poked Arlo. It fades in an hour.")
        let repeated = PokeReceipt(poke: Poke(fromID: me, toID: arlo, createdAt: ago(17)), isNew: false)
        XCTAssertEqual(PokeText.sent(name: "Arlo", receipt: repeated, now: now), "Arlo already has your poke. 43 min left.")
    }

    /// protects=the countdown never reads "0 min" and never more than the hour; the words and spoken
    /// sentences for every state in both directions; fails_when=any state loses its wording.
    func testCountdownWordsAndSpokenSentences() {
        XCTAssertEqual(PokeText.countdown(20), "1 min left")
        XCTAssertEqual(PokeText.countdown(3600), "1 h left")
        XCTAssertEqual(PokeText.countdown(9999), "1 h left")
        XCTAssertEqual(PokeText.ago(ago(0.5), now: now), "just now")
        XCTAssertEqual(PokeText.ago(ago(12), now: now), "12 min ago")

        let live = Poke(fromID: arlo, toID: me, createdAt: ago(8))
        let seen = Poke(fromID: arlo, toID: me, createdAt: ago(30), acknowledgedAt: ago(20), ackVia: .app)
        let back = Poke(fromID: arlo, toID: me, createdAt: ago(30), acknowledgedAt: ago(20), ackVia: .pokeBack)
        let faded = Poke(fromID: arlo, toID: me, createdAt: ago(200))
        XCTAssertEqual([live, seen, back, faded].map { PokeText.receivedWord($0.state(at: now)) },
                       ["POKED YOU", "YOU SAW IT", "YOU POKED BACK", "FADED"])
        XCTAssertEqual([live, seen, back, faded].map { PokeText.sentWord($0.state(at: now)) },
                       ["POKED", "SEEN", "POKED BACK", "FADED"])
        XCTAssertEqual(PokeText.timeLine(live, now: now), "52 min left")
        XCTAssertEqual(PokeText.timeLine(seen, now: now), "20 min ago")
        XCTAssertEqual(PokeText.spokenReceived(name: "Arlo", plan: "Brunch", poke: live, now: now), "Arlo poked you about Brunch, 52 min left")
        XCTAssertEqual(PokeText.spokenReceived(name: "Arlo", plan: nil, poke: faded, now: now), "Arlo poked you. It faded")
        XCTAssertEqual(PokeText.spokenSent(name: "Arlo", poke: back, now: now), "You poked Arlo. They poked back")
    }

    // MARK: Feed

    /// protects=the tab's four sections: live pokes to you (the badge), tag alongs on your plans, what
    /// you sent that is out or was answered within the hour, and the rest of the last day; a poke
    /// older than a day is gone and your own tag along is not news to you; fails_when=a poke lands in
    /// the wrong section or the badge counts something that is not answerable.
    func testFeedSections() {
        let live = Poke(fromID: arlo, toID: me, createdAt: ago(5))
        let older = Poke(fromID: maya, toID: me, createdAt: ago(40))
        let fadedIn = Poke(fromID: leo, toID: me, createdAt: ago(100))
        let out = Poke(fromID: me, toID: maya, createdAt: ago(10))
        let justSeen = Poke(fromID: me, toID: leo, createdAt: ago(50), acknowledgedAt: ago(30), ackVia: .push)
        let seenLongAgo = Poke(fromID: me, toID: arlo, createdAt: ago(300), acknowledgedAt: ago(290), ackVia: .app)
        let ancient = Poke(fromID: arlo, toID: me, createdAt: ago(25 * 60))
        let plan = UUID()
        let inbox = SocialInbox(
            pokes: [fadedIn, out, ancient, live, seenLongAgo, older, justSeen],
            tagAlongs: [TagAlongNotice(proposalID: plan, userID: leo, planTitle: "Tacos", createdAt: ago(3)),
                        TagAlongNotice(proposalID: plan, userID: me, planTitle: "Tacos", createdAt: ago(2)),
                        TagAlongNotice(proposalID: plan, userID: maya, planTitle: "Tacos", createdAt: ago(8 * 24 * 60))],
            names: [arlo: "Arlo", maya: "Maya", leo: "Leo"])
        let feed = PokeFeed.build(inbox, me: me, now: now)
        XCTAssertEqual(feed.forYou.map(\.id), [live.id, older.id], "newest first")
        XCTAssertEqual(feed.tagAlongs.map(\.userID), [leo])
        XCTAssertEqual(feed.sent.map(\.id), [out.id, justSeen.id])
        XCTAssertEqual(feed.earlier.map(\.id), [fadedIn.id, seenLongAgo.id])
        XCTAssertFalse(feed.isEmpty)
        XCTAssertTrue(PokeFeed.build(inbox, me: nil, now: now).isEmpty, "signed out reads nothing")
        XCTAssertEqual(feed.headline(names: inbox.name(of:), now: now), "Arlo and 1 more poked you. 55 min left on the newest.")
    }

    /// protects=the headline falls through in order: a poke for you, a tag along, your own poke's
    /// state, then the empty nudge; fails_when=an expired poke is announced as out.
    func testHeadlineFallsThrough() {
        func feed(_ pokes: [Poke], _ notices: [TagAlongNotice] = []) -> String {
            let inbox = SocialInbox(pokes: pokes, tagAlongs: notices, names: [arlo: "Arlo", leo: "Leo"])
            return PokeFeed.build(inbox, me: me, now: now).headline(names: inbox.name(of:), now: now)
        }
        XCTAssertEqual(feed([]), "Nobody is poking anybody. Start something.")
        XCTAssertEqual(feed([Poke(fromID: arlo, toID: me, createdAt: ago(1))]), "Arlo poked you. 59 min left.")
        XCTAssertEqual(feed([], [TagAlongNotice(proposalID: UUID(), userID: leo, planTitle: "Tacos", createdAt: ago(1))]),
                       "Leo is tagging along to Tacos.")
        XCTAssertEqual(feed([Poke(fromID: me, toID: arlo, createdAt: ago(15))]), "Your poke to Arlo is out. 45 min left.")
        XCTAssertEqual(feed([Poke(fromID: me, toID: arlo, createdAt: ago(15), acknowledgedAt: ago(1), ackVia: .pokeBack)]), "Arlo poked you back.")
        XCTAssertEqual(feed([Poke(fromID: me, toID: arlo, createdAt: ago(15), acknowledgedAt: ago(1), ackVia: .push)]), "Arlo saw your poke.")
        XCTAssertEqual(feed([Poke(fromID: me, toID: arlo, createdAt: ago(90))]), "Nobody is poking anybody. Start something.")
    }

    /// protects=every Poke button reads the one live poke you have out to that friend, so it can show
    /// time left instead of offering a second; fails_when=an expired, answered or incoming poke counts.
    func testLivePokeLookup() {
        let out = Poke(fromID: me, toID: arlo, createdAt: ago(10))
        let inbox = SocialInbox(pokes: [
            Poke(fromID: me, toID: arlo, createdAt: ago(200)), out,
            Poke(fromID: arlo, toID: me, createdAt: ago(1)),
            Poke(fromID: me, toID: maya, createdAt: ago(5), acknowledgedAt: ago(4), ackVia: .app),
        ], tagAlongs: [], names: [:])
        XCTAssertEqual(PokeFeed.livePoke(in: inbox, from: me, to: arlo, now: now)?.id, out.id)
        XCTAssertNil(PokeFeed.livePoke(in: inbox, from: me, to: maya, now: now))
        XCTAssertNil(PokeFeed.livePoke(in: inbox, from: nil, to: arlo, now: now))
    }

    /// protects=Home's poke list puts friends who have not answered a collecting plan first, keeps the
    /// given order inside each group and never lists you; on a locked plan nobody is "waiting";
    /// fails_when=the order reshuffles or you can poke yourself from Home.
    func testPokeTargetsPutTheQuietOnesFirst() {
        let people = [(id: me, name: "Sam"), (id: maya, name: "Maya"), (id: leo, name: "Leo"), (id: arlo, name: "Arlo")]
        let collecting = PokeTarget.order(members: people, answered: [maya], me: me, isCollecting: true)
        XCTAssertEqual(collecting.map(\.name), ["Leo", "Arlo", "Maya"])
        XCTAssertEqual(collecting.map(\.isWaiting), [true, true, false])
        let locked = PokeTarget.order(members: people, answered: [], me: me, isCollecting: false)
        XCTAssertEqual(locked.map(\.name), ["Maya", "Leo", "Arlo"])
        XCTAssertFalse(locked.contains(where: \.isWaiting))
    }

    // MARK: Tag along

    private func plan(status: ProposalStatus = .locked, attendees: [UUID], recipients: [UUID]? = nil, host: UUID? = nil,
                      startsIn hours: Double = 24, hidden: [UUID] = []) -> Proposal {
        var p = Proposal(id: UUID(), title: "Tacos", window: DateRange(lower: ago(60 * 24), upper: now.addingTimeInterval(14 * 86_400)),
                         createdBy: host ?? maya, distribution: Distribution(mode: .newGroup, recipientIDs: recipients ?? attendees + [me]),
                         status: status, hiddenFrom: hidden)
        if status == .locked {
            p.lockedDate = now.addingTimeInterval(hours * 3600)
            p.lockedEnd = now.addingTimeInterval(hours * 3600 + 7200)
            p.lockedAttendeeIDs = attendees
        }
        return p
    }

    /// protects=the client mirror of tag_along()'s checks, in the server's order: hidden reads as not
    /// found before anything else, then not locked, closed, over, already in; fails_when=a screen
    /// could offer Tag along on a plan the server refuses, or hint that a hidden plan exists.
    func testTagAlongRefusals() {
        XCTAssertNil(TagAlongRules.refusal(plan(attendees: [maya]), user: me, now: now))
        XCTAssertEqual(TagAlongRules.refusal(plan(attendees: [maya]), user: nil, now: now), .notFound)
        XCTAssertEqual(TagAlongRules.refusal(plan(status: .requesting, attendees: [], hidden: [me]), user: me, now: now), .notFound,
                       "hidden outranks every other answer")
        XCTAssertEqual(TagAlongRules.refusal(plan(status: .requesting, attendees: []), user: me, now: now), .notLocked)
        XCTAssertEqual(TagAlongRules.refusal(plan(status: .cancelled, attendees: []), user: me, now: now), .closed)
        XCTAssertEqual(TagAlongRules.refusal(plan(attendees: [maya], startsIn: -3), user: me, now: now), .over)
        XCTAssertEqual(TagAlongRules.refusal(plan(attendees: [maya, me]), user: me, now: now), .alreadyIn)
        XCTAssertTrue(TagAlongRules.canTagAlong(plan(attendees: [maya], startsIn: -1), user: me, now: now),
                      "a plan that started but has not ended can still be joined")
    }

    /// protects=a friend's joinable plans: they are going or hosting, you are not in, it is not over,
    /// soonest first; fails_when=the sheet lists a plan the friend is not on, or one you are already in.
    func testCandidatesAreTheFriendsOpenPlansSoonestFirst() {
        let later = plan(attendees: [leo], startsIn: 48)
        let sooner = plan(attendees: [leo, maya], startsIn: 5)
        let hosting = plan(attendees: [maya], host: leo, startsIn: 72)
        let notLeo = plan(attendees: [maya], startsIn: 2)
        let alreadyIn = plan(attendees: [leo, me], startsIn: 3)
        let over = plan(attendees: [leo], startsIn: -5)
        let open = plan(status: .requesting, attendees: [], recipients: [leo, me])
        let found = TagAlongRules.candidates([later, hosting, notLeo, alreadyIn, over, open, sooner], with: leo, me: me, now: now)
        XCTAssertEqual(found.map(\.id), [sooner.id, later.id, hosting.id])
        XCTAssertEqual(TagAlongRules.whoIsIn(sooner, friend: (leo, "Leo")), "Leo + 1 are in")
        XCTAssertEqual(TagAlongRules.whoIsIn(later, friend: (leo, "Leo")), "Leo is in")
        XCTAssertEqual(TagAlongRules.whoIsIn(hosting, friend: (leo, "Leo")), "1 is in")
        XCTAssertEqual(TagAlongRules.whoIsIn(sooner, friend: nil), "2 are in")
    }

    /// protects=the line the joiner reads: the host is told only when someone else hosts, and a missing
    /// host name falls back to "The host"; fails_when=the host is told about their own plan or the
    /// fallback disappears; no_claim=the push the host receives (social_test.sql section 7).
    func testJoinedCopyTellsTheHostOnlyWhenSomeoneElseHosts() {
        XCTAssertEqual(TagAlongRules.joinedText(planTitle: "Tacos", hostName: "Sam", isHost: true), "You're in for Tacos.")
        XCTAssertEqual(TagAlongRules.joinedText(planTitle: "Tacos", hostName: "Sam", isHost: false),
                       "You're in for Tacos. Sam has been told.")
        XCTAssertEqual(TagAlongRules.joinedText(planTitle: "Tacos", hostName: nil, isHost: false),
                       "You're in for Tacos. The host has been told.")
    }

    // MARK: Push route

    /// protects=a push tap is routed only from a well-formed `fc` payload; anything else opens the app
    /// and does nothing; fails_when=a malformed or unknown payload is guessed into a route.
    func testPushRouteParsesStrictly() {
        let id = UUID()
        XCTAssertEqual(PushRoute.parse(["aps": ["alert": "x"], "fc": ["kind": "poke", "poke_id": id.uuidString]]), .poke(id))
        XCTAssertEqual(PushRoute.parse(["fc": ["kind": "tag_along", "proposal_id": id.uuidString.lowercased(), "user_id": UUID().uuidString]]),
                       .tagAlong(proposalID: id))
        XCTAssertNil(PushRoute.parse(["fc": ["kind": "poke"]]))
        XCTAssertNil(PushRoute.parse(["fc": ["kind": "poke", "poke_id": "not-a-uuid"]]))
        XCTAssertNil(PushRoute.parse(["fc": ["kind": "mystery", "poke_id": id.uuidString]]))
        XCTAssertNil(PushRoute.parse(["kind": "poke", "poke_id": id.uuidString]), "the route lives under fc, not at the top level")
        XCTAssertNil(PushRoute.parse([:]))
        XCTAssertEqual(PushRoute(launchArgument: "poke/\(id.uuidString)"), .poke(id))
        XCTAssertEqual(PushRoute(launchArgument: "tagalong/\(id.uuidString)"), .tagAlong(proposalID: id))
        XCTAssertNil(PushRoute(launchArgument: "poke"))
    }

    // MARK: Errors

    /// protects=every refusal social.sql raises reads its own sentence, and an unmapped failure of a
    /// poke or a tag along never falls back to the lock wording the SQLSTATE table speaks;
    /// fails_when=a poke that failed reads "This plan is already locked."
    func testSocialRefusalsReadTheirOwnSentences() {
        func say(_ code: String, _ hint: String?, _ action: UserFacingError.Action) -> String {
            UserFacingError.map(ProposalStoreError.server(code: code, message: "raw", hint: hint), action: action).message
        }
        XCTAssertEqual(say("22023", "FC_SELF_POKE", .poke), "You can't poke yourself.")
        XCTAssertEqual(say("P0002", "FC_NOT_FRIEND", .poke), "You can only poke friends you share a plan with.")
        XCTAssertEqual(say("P0002", "FC_POKE_NOT_FOUND", .ackPoke), "That poke is gone.")
        XCTAssertEqual(say("55000", "FC_NOT_LOCKED", .tagAlong), "This plan isn't locked yet. Mark your times instead.")
        XCTAssertEqual(say("55000", "FC_PLAN_OVER", .tagAlong), "This plan already happened.")
        XCTAssertEqual(say("23P01", "FC_BUSY", .tagAlong), "You're already busy then.")
        XCTAssertEqual(say("P0002", "FC_NOT_FOUND", .tagAlong), "This plan is gone.")
        XCTAssertEqual(say("22023", "FC_BAD_TOKEN", .notifications), "Couldn't turn on notifications. Try again.")
        XCTAssertEqual(say("55000", nil, .poke), "Couldn't send that poke. Try again.")
        XCTAssertEqual(say("22023", nil, .tagAlong), "Couldn't tag along. Try again.")
        XCTAssertEqual(say("42501", nil, .poke), "Couldn't send that poke. Try again.")
        XCTAssertEqual(UserFacingError.map(ProposalStoreError.network("offline"), action: .ackPoke).message, "Couldn't update that poke. Try again.")
    }
}
