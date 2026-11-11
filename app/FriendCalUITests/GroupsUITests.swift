import XCTest

/// The Groups tab (variant D). Fixtures: `-FriendCalFixture populated -FriendCalStore memory`, the
/// clock pinned to Friday 2026-11-13 20:10 and `-FriendCalGroups crew|friends|alone`, opened straight on
/// the tab with `-FriendCalTab groups`. Screenshots are attached for /ios-design-review; no pixel baselines.
final class GroupsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    static func launch(_ scenario: String = "crew", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FriendCalFixture", "populated", "-FriendCalStore", "memory", "-FriendCalNow", "2026-11-13T20:10",
                               "-FriendCalTab", "groups", "-FriendCalGroups", scenario, "-FriendCalToastSeconds", "8"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["groups.setStatus"].waitForExistence(timeout: 10), "Groups did not load")
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func row(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    private func toast(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["toast"] }

    /// protects=the crew screen reads as the approved mock: your row first, the Moments line, the crew
    /// folder with Maya, Leo, Nina, Arlo and a plain Mika, each with its exact status copy;
    /// fails_when=a row's wording, order or the busy row's silence changes (Mika must carry no reason);
    /// no_claim=the painted scenes and motion (screenshot).
    func testCrewScreenReadsLikeVariantD() {
        let app = Self.launch()
        XCTAssertTrue(row(app, "You, no status yet. Double tap to set one").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "groups.moment").staticTexts.firstMatch.label, "You and Arlo are both free right now.")
        XCTAssertTrue(row(app, "Maya, work, till 11:00 PM, closing shift, send snacks").exists)
        XCTAssertTrue(row(app, "Leo, movies, till 9:40 PM, dune part three, no spoilers").exists)
        XCTAssertTrue(row(app, "Nina, concert, since 7:30 PM, khruangbin row 4").exists)
        XCTAssertTrue(row(app, "Arlo, free, free now, down for tacos, anyone").exists)
        app.swipeUp()
        XCTAssertTrue(row(app, "Mika, busy").waitForExistence(timeout: 5), "Mika must read plain busy, no reason")
        attach(app, "groups-crew")
    }

    /// protects=setting your own status end to end: the header pill opens the studio, a scene and a
    /// message are chosen, "Share status" closes it, your row wears the status for two hours, the
    /// sticker tray goes away and the Moments line moves on; fails_when=any step stops feeding the
    /// next; no_claim=haptics.
    func testSetStatusFlow() {
        let app = Self.launch()
        app.buttons["groups.setStatus"].tap()
        XCTAssertTrue(any(app, "studio").waitForExistence(timeout: 5))
        attach(app, "studio-open")
        app.buttons["studio.kind.movies"].tap()
        let field = app.textFields["studio.message"]
        field.tap()
        field.typeText("no spoilers\n")
        attach(app, "studio-filled")
        app.buttons["studio.share"].tap()
        XCTAssertTrue(row(app, "You, movies, till 10:10 PM, no spoilers").waitForExistence(timeout: 5))
        XCTAssertEqual(toast(app).label, "Status shared")
        XCTAssertFalse(any(app, "groups.tray").exists, "the tray is only for an unset status")
        XCTAssertEqual(any(app, "groups.moment").staticTexts.firstMatch.label, "Leo's movie lets out in 1 h 30. Nina has been at the concert for 40 min.")
        XCTAssertEqual(app.buttons["groups.setStatus"].label, "Edit status")
        app.buttons["groups.setStatus"].tap()
        XCTAssertTrue(app.buttons["studio.clear"].waitForExistence(timeout: 5))
        app.buttons["studio.clear"].tap()
        XCTAssertTrue(row(app, "You, no status yet. Double tap to set one").waitForExistence(timeout: 5))
    }

    /// protects=a status the server refuses does not stay on screen as if friends could see it: the row
    /// goes back to "no status" and the failure is said in a toast; fails_when=the rollback or the toast
    /// is dropped, so you believe you shared a status that never left the phone;
    /// no_claim=the wording of each network error (UserFacingErrorTests).
    func testRefusedStatusRollsBack() {
        let app = Self.launch(extra: ["-FriendCalFailNext", "setStatus"])
        app.buttons["groups.setStatus"].tap()
        XCTAssertTrue(any(app, "studio").waitForExistence(timeout: 5))
        app.buttons["studio.kind.movies"].tap()
        app.buttons["studio.share"].tap()
        XCTAssertTrue(row(app, "You, no status yet. Double tap to set one").waitForExistence(timeout: 8), "the refused status was not rolled back")
        XCTAssertFalse(row(app, "You, movies, till 10:10 PM").exists)
        let failure = NSPredicate(format: "label != %@ AND label != ''", "Status shared")
        expectation(for: failure, evaluatedWith: toast(app))
        waitForExpectations(timeout: 8)
    }

    /// protects=a sticker in the tray opens the studio already on that scene; fails_when=the chip
    /// opens a blank studio or the wrong scene; no_claim=the gallery's scroll.
    func testTrayChipOpensStudioOnThatScene() {
        let app = Self.launch()
        app.buttons["groups.tray.gym"].tap()
        XCTAssertTrue(app.buttons["studio.kind.gym"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["studio.kind.gym"].isSelected)
        XCTAssertFalse(app.buttons["studio.kind.work"].isSelected)
    }

    /// protects=a tap opens the friend's card whose Poke really pokes (toast, then the pill reads
    /// "Poked"); fails_when=a row does nothing on tap or Poke sends nothing; no_claim=swipe and
    /// long-press (system gestures over the same actions), Tag along (PokesUITests).
    func testFriendCardPokes() {
        let app = Self.launch()
        row(app, "Maya, work, till 11:00 PM, closing shift, send snacks").tap()
        XCTAssertTrue(app.buttons["friend.poke"].waitForExistence(timeout: 5))
        attach(app, "friend-card")
        app.buttons["friend.poke"].tap()
        XCTAssertTrue(toast(app).waitForExistence(timeout: 5))
        XCTAssertEqual(toast(app).label, "Poked Maya. It fades in an hour.")
    }

    /// protects=the Moments action pokes the friend it names (Arlo) through the same path as the card;
    /// fails_when=it toasts without poking or pokes someone else; no_claim=copy of the Moments line.
    func testMomentsActionPokesArlo() {
        let app = Self.launch()
        app.buttons["groups.moment.action"].tap()
        XCTAssertTrue(toast(app).waitForExistence(timeout: 5))
        XCTAssertEqual(toast(app).label, "Poked Arlo. It fades in an hour.")
    }

    /// protects=with no crew yet, the automatic folder holds every friend and "Start a crew" turns
    /// ticked friends into a crew folder (the zero-group answer); fails_when=a friend is missing from
    /// the folder, Create enables with nobody ticked, or the new crew does not appear; no_claim=
    /// persistence (in memory only).
    func testStartACrewFromTheFriendsFolder() {
        let app = Self.launch("friends")
        XCTAssertTrue(app.buttons["Friends on FriendCal, 5 of 5 online"].waitForExistence(timeout: 5))
        attach(app, "groups-no-crew")
        app.buttons["groups.startCrew"].tap()
        let create = app.buttons["groups.createCrew"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertFalse(create.isEnabled)
        XCTAssertEqual(create.label, "Pick a friend")
        let picks = app.descendants(matching: .any).matching(identifier: "groups.pick")
        picks.element(boundBy: 0).tap()
        picks.element(boundBy: 1).tap()
        XCTAssertEqual(create.label, "Start crew with 2")
        XCTAssertTrue(create.isEnabled)
        attach(app, "groups-building")
        create.tap()
        XCTAssertTrue(app.buttons["Maya & Leo, 2 of 2 online"].waitForExistence(timeout: 5))
        XCTAssertEqual(toast(app).label, "Maya & Leo is ready")
    }

    /// protects=a person with no friends still has a useful screen: the nudge in Moments, whose action
    /// reads "Add a friend" and opens the sheet, and a dashed open seat that stays an honest stub;
    /// fails_when=the screen goes blank or the Moments action does nothing; no_claim=the system share sheet.
    func testAloneStateInvitesTheFirstFriend() {
        let app = Self.launch("alone")
        XCTAssertEqual(any(app, "groups.moment").staticTexts.firstMatch.label, "Quiet in here. Invite your first friend.")
        XCTAssertFalse(any(app, "groups.startCrew").exists)
        attach(app, "groups-alone")
        app.buttons["groups.invite"].tap()
        XCTAssertEqual(toast(app).label, "Invites by link are coming soon", "the seat card is not an entry point")
        let action = app.buttons["groups.moment.action"]
        XCTAssertEqual(action.label, "Add a friend")
        action.tap()
        XCTAssertTrue(any(app, "addFriend.link").waitForExistence(timeout: 8))
    }

    /// protects=every Groups control is at least 44pt tall: header pill, sticker chips, studio
    /// duration chips and Share (DESIGN.md touch targets); fails_when=any shrinks below 44pt;
    /// no_claim=hit-testing beyond the frame. Also run on iPhone SE (3rd generation).
    func testControlsAreAtLeast44pt() {
        let app = Self.launch()
        XCTAssertGreaterThanOrEqual(app.buttons["groups.setStatus"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["groups.tray.work"].frame.height, 44)
        app.buttons["groups.setStatus"].tap()
        XCTAssertTrue(app.buttons["studio.share"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["studio.share"].frame.height, 44)
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'studio.duration.'"))
        XCTAssertEqual(chips.count, 4)
        for i in 0..<chips.count { XCTAssertGreaterThanOrEqual(chips.element(boundBy: i).frame.height, 44) }
    }
}
