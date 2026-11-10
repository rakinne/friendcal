import XCTest
@testable import FriendCalCore

/// Groups (variant D) logic: statuses, presence, row copy, durations, folders, the crew draft,
/// Moments and the day ribbon. Fixed New York calendar; Friday 2026-11-13 20:10 is "now".
final class GroupsLogicTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ h: Int, _ m: Int = 0, day: Int = 13) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))!
    }

    private var now: Date { at(20, 10) }
    private let maya = Buddy(id: UUID(), name: "Maya")
    private let leo = Buddy(id: UUID(), name: "Leo")
    private let nina = Buddy(id: UUID(), name: "Nina")
    private let arlo = Buddy(id: UUID(), name: "Arlo")
    private let mika = Buddy(id: UUID(), name: "Mika", isOnline: false)

    // MARK: Status

    /// protects=a message is one trimmed line capped at 60 characters; fails_when=newlines survive
    /// into a row (it would grow past the plate), whitespace pads it, or the cap moves;
    /// no_claim=how the plate truncates visually.
    func testMessageIsOneTrimmedLineCappedAt60() {
        XCTAssertEqual(FriendStatus.clean("  closing shift\nsend snacks  "), "closing shift send snacks")
        let long = String(repeating: "a", count: 90)
        XCTAssertEqual(FriendStatus.clean(long).count, FriendStatus.maxMessageLength)
        XCTAssertEqual(FriendStatus(kind: .work, message: "\n \n", since: now).message, "")
    }

    /// protects=a status with an end stops being active at that instant and an open one never does;
    /// fails_when=the boundary flips (an ended status lingering a tick) or open-ended expires;
    /// no_claim=clock skew between devices.
    func testStatusActiveUntilItsEndExclusive() {
        let s = FriendStatus(kind: .movies, since: at(19, 30), until: at(21, 40))
        XCTAssertTrue(s.isActive(at: at(21, 39)))
        XCTAssertFalse(s.isActive(at: at(21, 40)))
        XCTAssertTrue(FriendStatus(kind: .gym, since: at(8)).isActive(at: at(23, 59)))
    }

    /// protects=every kind has its own SF Symbol, so states tell apart by shape and not hue (D25);
    /// fails_when=two kinds share a glyph or a word; no_claim=that each symbol exists on the OS (the
    /// UI test and previews draw them).
    func testEveryKindHasItsOwnGlyphAndWord() {
        XCTAssertEqual(Set(StatusKind.allCases.map(\.symbolName)).count, StatusKind.allCases.count)
        XCTAssertEqual(Set(StatusKind.allCases.map(\.word)).count, StatusKind.allCases.count)
        XCTAssertFalse(StatusKind.allCases.map(\.symbolName).contains(StatusKind.busySymbolName))
    }

    // MARK: Presence (the stealth line)

    /// protects=busy carries no reason: an expired status does not leak its message into busy, and a
    /// busy person with no status reads exactly the same as anyone else who is busy (X1); fails_when=
    /// Presence.busy ever gains a payload or an expired status survives resolve; no_claim=server
    /// sanitization of Stealth rows (StealthTests, BusyBlockSanitizeTests).
    func testBusyNeverCarriesAReasonAndExpiredStatusDoesNotLeak() {
        let expired = FriendStatus(kind: .work, message: "surprise party prep", since: at(9), until: at(17))
        XCTAssertEqual(Presence.resolve(status: expired, isBusy: true, now: now), .busy)
        XCTAssertEqual(Presence.resolve(status: nil, isBusy: true, now: now), .busy)
        XCTAssertEqual(Presence.resolve(status: expired, isBusy: false, now: now), .quiet)
        XCTAssertEqual(Presence.busy.rowText(name: "Mika", now: now, calendar: calendar).message, nil)
        XCTAssertEqual(Presence.busy.rowText(name: "Mika", now: now, calendar: calendar).spoken, "Mika, busy")
    }

    /// protects=a live status wins over busy, because the person chose to say it; fails_when=busy
    /// hides a status someone set; no_claim=anything about who may see the status.
    func testLiveStatusBeatsBusy() {
        let work = FriendStatus(kind: .work, message: "closing shift", since: at(16), until: at(23))
        XCTAssertEqual(Presence.resolve(status: work, isBusy: true, now: now), .status(work))
    }

    // MARK: Row copy

    /// protects=the row lines match the approved mock: "till 11:00 PM" with an end, "since 7:30 PM"
    /// without, "free now" for open-ended free, and a spoken sentence for VoiceOver; fails_when=any
    /// wording or the 12-hour format drifts; no_claim=other locales (the format is fixed en_US_POSIX).
    func testRowTextMatchesTheApprovedCopy() {
        let work = Presence.status(FriendStatus(kind: .work, message: "closing shift, send snacks", since: at(16), until: at(23)))
        XCTAssertEqual(work.rowText(name: "Maya", now: now, calendar: calendar),
                       RowText(message: "closing shift, send snacks", time: "till 11:00 PM",
                               spoken: "Maya, work, till 11:00 PM, closing shift, send snacks"))
        let concert = Presence.status(FriendStatus(kind: .concert, message: "khruangbin row 4", since: at(19, 30)))
        XCTAssertEqual(concert.rowText(name: "Nina", now: now, calendar: calendar).time, "since 7:30 PM")
        let free = Presence.status(FriendStatus(kind: .free, message: "down for tacos, anyone", since: at(20)))
        XCTAssertEqual(free.rowText(name: "Arlo", now: now, calendar: calendar).time, "free now")
        XCTAssertEqual(Presence.quiet.rowText(name: "You", isYou: true, now: now).message, "set your status")
        XCTAssertNil(Presence.quiet.rowText(name: "Leo", now: now).message)
    }

    func testSpanWording() {
        XCTAssertEqual(TimeText.span(40 * 60), "40 min")
        XCTAssertEqual(TimeText.span(90 * 60), "1 h 30")
        XCTAssertEqual(TimeText.span(120 * 60), "2 h")
        XCTAssertEqual(TimeText.span(5), "1 min")
    }

    // MARK: Durations

    /// protects=the sheet's four durations: 1 h and 2 h are relative, "tonight" is 11 PM (midnight
    /// when under 30 minutes away) and "all night" is the next 7 AM at least 30 minutes out; fails_when=
    /// a chip lands in the past or a minute from now; no_claim=daylight-saving transitions.
    func testDurations() {
        XCTAssertEqual(StatusDuration.oneHour.end(from: now, calendar: calendar), at(21, 10))
        XCTAssertEqual(StatusDuration.twoHours.end(from: now, calendar: calendar), at(22, 10))
        XCTAssertEqual(StatusDuration.tonight.end(from: now, calendar: calendar), at(23))
        XCTAssertEqual(StatusDuration.tonight.end(from: at(22, 50), calendar: calendar), at(0, day: 14))
        XCTAssertEqual(StatusDuration.allNight.end(from: now, calendar: calendar), at(7, day: 14))
        XCTAssertEqual(StatusDuration.allNight.end(from: at(6, 50), calendar: calendar), at(7, day: 14))
        XCTAssertEqual(StatusDuration.allNight.end(from: at(2), calendar: calendar), at(7))
        XCTAssertEqual(StatusDuration.tonight.label(from: now, calendar: calendar), "till 11 PM")
    }

    // MARK: Folders

    /// protects=crews first in the order given, then the automatic folder with everyone not in a
    /// crew; fails_when=a friend lands in two folders by accident, a departed id leaves a hole, or order
    /// changes with status; no_claim=a friend placed in two crews on purpose (allowed, shown in both).
    func testFoldersPlaceEveryFriendOnce() {
        let crew = Crew(name: "Friendsgivemas Crew", memberIDs: [maya.id, leo.id, UUID()])
        let folders = GroupsLayout.folders(crews: [crew], friends: [maya, leo, nina])
        XCTAssertEqual(folders.map(\.title), ["Friendsgivemas Crew", GroupsFolder.friendsTitle])
        XCTAssertEqual(folders[0].members, [maya, leo])
        XCTAssertEqual(folders[1].members, [nina])
        XCTAssertTrue(folders[1].isAutomatic)
    }

    /// protects=the automatic folder is hidden once everyone has a crew, and present (empty) when
    /// there are no crews at all, where it hosts the invite card; fails_when=a blank folder header
    /// shows beside crews, or a new user with no friends gets no folder; no_claim=its look.
    func testAutomaticFolderVisibility() {
        let crew = Crew(name: "Brunch Club", memberIDs: [maya.id])
        XCTAssertEqual(GroupsLayout.folders(crews: [crew], friends: [maya]).map(\.title), ["Brunch Club"])
        let alone = GroupsLayout.folders(crews: [], friends: [])
        XCTAssertEqual(alone.map(\.title), [GroupsFolder.friendsTitle])
        XCTAssertTrue(alone[0].members.isEmpty)
    }

    func testOnlineCount() {
        let folder = GroupsFolder(kind: .friends, title: "x", members: [maya, mika])
        XCTAssertEqual(folder.onlineCount, 1)
    }

    // MARK: Crew draft

    /// protects=a crew needs one friend, the name falls back to the first names ticked, and a typed
    /// name is trimmed and capped at 30; fails_when=Create enables with nobody ticked or the cap moves;
    /// no_claim=duplicate crew names (allowed).
    func testCrewDraftRules() {
        var draft = CrewDraft()
        XCTAssertFalse(draft.canCreate)
        XCTAssertEqual(draft.resolvedName(among: [maya]), "My crew")
        draft.toggle(maya.id)
        XCTAssertTrue(draft.canCreate)
        XCTAssertEqual(draft.resolvedName(among: [maya, leo]), "You & Maya")
        draft.toggle(leo.id)
        XCTAssertEqual(draft.resolvedName(among: [maya, leo]), "Maya & Leo")
        draft.toggle(arlo.id)
        XCTAssertEqual(draft.resolvedName(among: [maya, leo, arlo]), "Maya, Leo & 1 more")
        draft.toggle(maya.id)
        XCTAssertEqual(draft.selected, [leo.id, arlo.id])
        draft.name = "  " + String(repeating: "x", count: 50)
        XCTAssertEqual(draft.resolvedName(among: []).count, CrewDraft.maxNameLength)
    }

    // MARK: Moments

    private func presence(_ map: [UUID: FriendStatus], busy: Set<UUID> = []) -> (UUID) -> Presence {
        { Presence.resolve(status: map[$0], isBusy: busy.contains($0), now: self.now) }
    }

    /// protects=the headline overlap line names who is free and quotes their message, with a Poke for
    /// them; fails_when=it triggers when the viewer is busy, picks a busy friend, or loses the message;
    /// no_claim=copy beyond this case.
    func testBothFreeComesFirst() {
        let statuses = [
            arlo.id: FriendStatus(kind: .free, message: "down for tacos, anyone", since: at(20)),
            leo.id: FriendStatus(kind: .movies, since: at(19, 35), until: at(21, 40)),
        ]
        let m = MomentsEngine.moment(friends: [maya, leo, arlo], presence: presence(statuses, busy: [maya.id]), viewerFree: true, now: now, calendar: calendar)
        XCTAssertEqual(m.text, "You and Arlo are both free right now.")
        XCTAssertEqual(m.detail, "down for tacos, anyone")
        XCTAssertEqual(m.action, .poke(arlo.id, name: "Arlo"))
        let busyViewer = MomentsEngine.moment(friends: [maya, leo, arlo], presence: presence(statuses), viewerFree: false, now: now, calendar: calendar)
        XCTAssertFalse(busyViewer.text.contains("both free"))
    }

    /// protects=with no overlap the line is the approved "ending soon plus longest stay" copy, never
    /// naming a busy friend; fails_when=a busy friend appears, the same person is named twice, or a
    /// stay under 20 minutes is mentioned; no_claim=more than two clauses.
    func testEndingSoonAndLongestStay() {
        let statuses = [
            leo.id: FriendStatus(kind: .movies, message: "dune", since: at(19, 35), until: at(21, 40)),
            nina.id: FriendStatus(kind: .concert, since: at(19, 30)),
            maya.id: FriendStatus(kind: .work, since: at(20, 5), until: at(23)),
        ]
        let m = MomentsEngine.moment(friends: [maya, leo, nina, mika], presence: presence(statuses, busy: [mika.id]), viewerFree: false, now: now, calendar: calendar)
        XCTAssertEqual(m.text, "Leo's movie lets out in 1 h 30. Nina has been at the concert for 40 min.")
        XCTAssertNil(m.action)
        XCTAssertFalse(m.text.contains("Mika"))
    }

    /// protects=the empty cases still say something useful: no friends invites the first, friends with
    /// no statuses nudges you to set yours; fails_when=either returns a blank card; no_claim=copy tone.
    func testQuietAndEmptyMoments() {
        XCTAssertEqual(MomentsEngine.moment(friends: [], presence: { _ in .quiet }, viewerFree: true, now: now).action, .invite)
        let nudge = MomentsEngine.moment(friends: [maya], presence: { _ in .quiet }, viewerFree: true, now: now)
        XCTAssertEqual(nudge.action, .setStatus)
        let after = MomentsEngine.moment(friends: [maya], presence: { _ in .quiet }, viewerFree: true, viewerHasStatus: true, now: now)
        XCTAssertNil(after.action)
    }

    // MARK: Day ribbon

    /// protects=the ribbon clips to today, draws an open-ended status up to now, puts the status
    /// over busy time, and widens a sliver so it stays visible; fails_when=a segment spills past 0...1
    /// or a short block vanishes; no_claim=drawing.
    func testRibbonSegments() {
        let status = FriendStatus(kind: .concert, since: at(19, 30))
        let busy = [DateInterval(start: at(0, 30, day: 12), end: at(1, day: 12))] // yesterday: clipped away
        let segs = DayRibbon.segments(status: status, busy: busy, now: now, calendar: calendar)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].kind, .status(.concert))
        XCTAssertEqual(segs[0].start, (19.5 / 24), accuracy: 0.0001)
        XCTAssertEqual(segs[0].end, (20 + 10.0 / 60) / 24, accuracy: 0.0001)
        let sliver = DayRibbon.segments(status: nil, busy: [DateInterval(start: at(12), end: at(12, 1))], now: now, calendar: calendar)
        XCTAssertGreaterThanOrEqual(sliver[0].end - sliver[0].start, 15.0 * 60 / 86_400 - 0.0001)
        XCTAssertEqual(DayRibbon.fraction(of: at(12), now: now, calendar: calendar), 0.5, accuracy: 0.0001)
    }
}
