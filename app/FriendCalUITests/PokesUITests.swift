import XCTest

/// Poke and Tag along: the Pokes tab, the tag-along sheet, and the 44pt floor on their controls.
/// Fixtures: `-FriendCalFixture populated -FriendCalStore memory`, the clock pinned to Friday 2026-11-13
/// 20:10, `-FriendCalPokes inbox` (Arlo's poke 8 min old, my pokes to Nina and Leo, Maya's 150 min old and
/// faded) and `-FriendCalTagAlong plan` (Leo hosts a locked "Tacos" I am not in).
final class PokesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    static func launch(tab: String = "pokes", inbox: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FriendCalFixture", "populated", "-FriendCalStore", "memory", "-FriendCalNow", "2026-11-13T20:10",
                               "-FriendCalTab", tab, "-FriendCalGroups", "crew", "-FriendCalToastSeconds", "8"]
            + (inbox ? ["-FriendCalPokes", "inbox"] : []) + extra
        app.launch()
        return app
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func toast(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["toast"] }
    private func row(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Sheets open at their medium detent, where SwiftUI reads controls about 4% short (42.25pt for a 44pt
    /// one, the same quirk LockedInviteUITests documents). The floor is asserted at the large detent.
    private func expandSheet(_ app: XCUIApplication) {
        let w = app.windows.firstMatch
        w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
            .press(forDuration: 0.1, thenDragTo: w.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
    }

    private func assertAtLeast44(_ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(name) missing", file: file, line: line)
        // Let a sheet finish presenting: mid-animation frames are scaled and read a few points short.
        let settled = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        wait(for: [settled], timeout: 5)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44 - 0.01, "\(name) is shorter than 44pt", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, 44 - 0.01, "\(name) is narrower than 44pt", file: file, line: line)
    }

    /// Opens Leo's card on Groups, then Tag along. The sheet opens after the card has dismissed.
    private func openTagAlongWithLeo(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["groups.setStatus"].waitForExistence(timeout: 10), "Groups did not load")
        row(app, "Leo, movies, till 9:40 PM, dune part three, no spoilers").tap()
        XCTAssertTrue(app.buttons["friend.tagAlong"].waitForExistence(timeout: 5))
        app.buttons["friend.tagAlong"].tap()
        XCTAssertTrue(any(app, "tagAlong").waitForExistence(timeout: 5))
    }

    // MARK: Pokes tab

    /// protects=the feed sorts what is aimed at you: Arlo's live poke under "For you", the two I sent
    /// under "Sent", Maya's faded one under "Earlier"; fails_when=a poke lands in the wrong section or
    /// a faded one is still offered a reply; no_claim=scene art and the fuse (screenshot).
    func testFeedSortsPokesIntoSections() {
        let app = Self.launch()
        XCTAssertTrue(any(app, "pokes.forYou").waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "pokes.forYou").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "pokes.pokeBack").count, 1, "only the live poke can be poked back")
        XCTAssertTrue(any(app, "pokes.sent").exists)
        app.swipeUp()
        XCTAssertTrue(any(app, "pokes.earlier").waitForExistence(timeout: 5))
        attach(app, "pokes-feed")
    }

    /// protects=Poke back sends a poke to the sender and takes their poke out of "For you" (it is
    /// answered on the server); fails_when=no toast, or the poke stays in "For you"; no_claim=the push.
    func testPokeBackAnswersTheirPoke() {
        let app = Self.launch()
        XCTAssertTrue(app.buttons["pokes.pokeBack"].waitForExistence(timeout: 10))
        app.buttons["pokes.pokeBack"].tap()
        XCTAssertTrue(toast(app).waitForExistence(timeout: 5))
        XCTAssertEqual(toast(app).label, "Poked Arlo. It fades in an hour.")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: any(app, "pokes.forYou"))
        wait(for: [gone], timeout: 5)
    }

    /// protects=Got it acknowledges a poke without poking back; fails_when=it stays in "For you" or
    /// sends a poke; no_claim=the acknowledgement push to the sender.
    func testGotItClearsThePokeWithoutSending() {
        let app = Self.launch()
        XCTAssertTrue(app.buttons["pokes.gotIt"].waitForExistence(timeout: 10))
        app.buttons["pokes.gotIt"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: any(app, "pokes.forYou"))
        wait(for: [gone], timeout: 5)
        XCTAssertFalse(toast(app).exists, "Got it must not send a poke, and sends nothing worth a toast")
    }

    /// protects=with nothing in the inbox the tab says so and points at Groups instead of a blank list;
    /// fails_when=a blank list or the empty card missing; no_claim=copy.
    func testEmptyInboxShowsEmptyCard() {
        let app = Self.launch(inbox: false)
        XCTAssertTrue(any(app, "pokes.empty").waitForExistence(timeout: 10))
        attach(app, "pokes-empty")
    }

    // MARK: Who needs a poke

    /// protects=a send that fails says so in a toast and leaves the row pokeable; fails_when=the row
    /// reads "Poked" after a refusal or no toast appears; no_claim=the wording per error (unit tests).
    func testFailedPokeLeavesTheRowPokeable() {
        let app = HomeUITests.launch(extra: ["-FriendCalFailNext", "sendPoke", "-FriendCalToastSeconds", "8"])
        app.buttons["home.poke"].tap()
        let pill = app.buttons["pokePicker.poke"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        pill.tap()
        XCTAssertTrue(toast(app).waitForExistence(timeout: 5))
        XCTAssertFalse(toast(app).label.hasPrefix("Poked"))
        XCTAssertTrue(app.buttons["pokePicker.poke"].firstMatch.label.hasPrefix("Poke "), "the row must stay pokeable")
    }

    // MARK: Tag along

    /// protects=Tag along joins a locked plan I was sent: the card hands off to the sheet, the plan is
    /// listed with its time, joining toasts the plan's name and closes the sheet; fails_when=the sheet
    /// never opens, the plan is missing, or joining does nothing; no_claim=the host's push.
    func testTagAlongJoinsLeosPlan() {
        let app = Self.launch(tab: "groups", inbox: false, extra: ["-FriendCalTagAlong", "plan"])
        openTagAlongWithLeo(app)
        XCTAssertTrue(any(app, "tagAlong.plan").waitForExistence(timeout: 5))
        attach(app, "tag-along-sheet")
        app.buttons["tagAlong.join"].tap()
        let joined = app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND label CONTAINS 'Tacos'")).firstMatch
        XCTAssertTrue(joined.waitForExistence(timeout: 5))
    }

    /// protects=a friend with no plan to join gets a reason to poke, not a dead end; fails_when=the
    /// empty state is blank or its Poke pill does not poke; no_claim=copy.
    func testTagAlongWithNothingToJoinOffersAPoke() {
        let app = Self.launch(tab: "groups", inbox: false)
        openTagAlongWithLeo(app)
        XCTAssertTrue(any(app, "tagAlong.empty").waitForExistence(timeout: 5))
        app.buttons["tagAlong.poke"].tap()
        XCTAssertTrue(toast(app).waitForExistence(timeout: 5))
        XCTAssertEqual(toast(app).label, "Poked Leo. It fades in an hour.")
    }

    /// protects=a refused join keeps the plan listed and says why, so it can be retried; fails_when=
    /// the sheet closes, the plan disappears, or nothing explains; no_claim=the exact sentence.
    func testFailedTagAlongKeepsThePlan() {
        let app = Self.launch(tab: "groups", inbox: false, extra: ["-FriendCalTagAlong", "plan", "-FriendCalFailNext", "tagAlong"])
        openTagAlongWithLeo(app)
        XCTAssertTrue(app.buttons["tagAlong.join"].waitForExistence(timeout: 5))
        app.buttons["tagAlong.join"].tap()
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 5), "a refusal must be explained inline")
        XCTAssertTrue(app.buttons["tagAlong.join"].exists)
    }

    // MARK: 44pt

    /// protects=Poke back, Got it, the picker's pills and Done, and the card's Tag along are all at
    /// least 44 x 44pt; fails_when=any shrinks below that. Also run on iPhone SE (3rd generation).
    func testPokeControlsAreAtLeast44pt() {
        let feed = Self.launch()
        assertAtLeast44(feed.buttons["pokes.pokeBack"], "Poke back")
        assertAtLeast44(feed.buttons["pokes.gotIt"], "Got it")
        feed.terminate()

        let home = HomeUITests.launch()
        home.buttons["home.poke"].tap()
        expandSheet(home)
        assertAtLeast44(home.buttons["pokePicker.poke"].firstMatch, "picker Poke")
        assertAtLeast44(home.buttons["pokePicker.done"], "picker Done")
        home.terminate()

        let groups = Self.launch(tab: "groups", inbox: false, extra: ["-FriendCalTagAlong", "plan"])
        openTagAlongWithLeo(groups)
        expandSheet(groups)
        assertAtLeast44(groups.buttons["tagAlong.join"], "Tag along join")
        assertAtLeast44(groups.buttons["tagAlong.close"], "Tag along Close")
    }
}
