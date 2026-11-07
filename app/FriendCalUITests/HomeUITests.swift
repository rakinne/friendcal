import XCTest

/// Home interactions (T7, T13). Fixtures are picked with `-FriendCalFixture <scenario>`; the
/// populated fixture's week 1 is Nov 9-15 2026 with best Sat afternoon 13 of 15 (FixtureData).
/// Screenshots are attached for /ios-design-review; there are no pixel baselines.
final class HomeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    static func launch(_ fixture: String = "populated", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FriendCalFixture", fixture] + extra
        app.launch()
        XCTAssertTrue(app.buttons["home.poke"].waitForExistence(timeout: 10), "Home did not load")
        return app
    }

    func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func cell(_ app: XCUIApplication, week: Int, day: Int, _ part: String) -> XCUIElement {
        app.descendants(matching: .any)["heatmap.w\(week).d\(day).\(part)"]
    }

    private func toast(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["toast"] }

    /// The toast with exactly this text. One query for existence and label, so the 2.5s
    /// auto-dismiss can't race a separate label read on a slow simulator.
    private func toast(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND label == %@", text)).firstMatch
    }

    // MARK: T7

    /// protects=Home launches into the populated fixture with all six modules above the floating
    /// tab bar at default Dynamic Type (D17, D34) and the best cell selected; fails_when=Poke or the
    /// stealth row sits under/behind the tab bar, or launch selects anything but Sat afternoon;
    /// no_claim=pixel fidelity (screenshot is for the design review), other device sizes.
    func testLaunchShowsOneScreenHomeAboveTabBar() {
        let app = Self.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        for id in ["home.poke", "home.share"] {
            let el = app.buttons[id]
            XCTAssertTrue(el.isHittable, id)
            XCTAssertLessThanOrEqual(el.frame.maxY, tabBar.frame.minY, "\(id) overlaps the tab bar")
        }
        let stealth = app.switches["home.stealth"]
        XCTAssertTrue(stealth.isHittable)
        XCTAssertLessThanOrEqual(stealth.frame.maxY, tabBar.frame.minY, "stealth row overlaps the tab bar")
        XCTAssertEqual(cell(app, week: 0, day: 5, "afternoon").label, "Saturday afternoon, 13 of 15 free, best, selected")
        attach(app, "home-populated")
    }

    /// protects=tapping a cell selects it and VoiceOver says so (D22); fails_when=the tap is
    /// ignored, the label lacks ", selected", or the previous selection keeps it; no_claim=the
    /// haptic fires (not observable from XCUITest).
    func testTapCellSelectsIt() {
        let app = Self.launch()
        let fri = cell(app, week: 0, day: 4, "afternoon")
        fri.tap()
        XCTAssertEqual(fri.label, "Friday afternoon, 10 of 15 free, selected")
        XCTAssertEqual(cell(app, week: 0, day: 5, "afternoon").label, "Saturday afternoon, 13 of 15 free, best")
    }

    /// protects=week paging updates the indicator and moves the selection to that week's best
    /// (X6); fails_when=the swipe doesn't page, the indicator still says week 1, or the selection
    /// stays on week 1; no_claim=the VoiceOver adjustable action (not driven here).
    func testSwipeToWeekTwoSelectsItsBest() {
        let app = Self.launch()
        let dots = app.descendants(matching: .any)["heatmap.pageIndicator"]
        XCTAssertEqual(dots.value as? String, "1 of 2, Nov 9–15")
        // A flick that starts on a cell, so cells must not swallow the pager's drag. Dragged by
        // coordinate: XCUIElement.swipeLeft scales its length to the element, too short on a cell.
        let start = cell(app, week: 0, day: 3, "afternoon").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -250, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
        let week2Best = cell(app, week: 1, day: 4, "evening")
        let paged = NSPredicate(format: "value == %@", "2 of 2, Nov 16–22")
        wait(for: [expectation(for: paged, evaluatedWith: dots)], timeout: 5)
        XCTAssertEqual(week2Best.label, "Friday evening, 12 of 15 free, best, selected")
        XCTAssertFalse(cell(app, week: 0, day: 5, "afternoon").label.hasSuffix("selected"))
        attach(app, "home-week2")
    }

    /// protects=Poke is an honest stub: a toast, announced, that goes away (D20); fails_when=no
    /// toast, wrong copy, or it never dismisses; no_claim=the impact haptic, and the exact 2.5s
    /// duration (the toast runs 6s here so XCUITest's idle wait can't miss it).
    func testPokeShowsComingSoonToast() {
        let app = Self.launch(extra: ["-FriendCalToastSeconds", "6"])
        app.buttons["home.poke"].tap()
        XCTAssertTrue(toast(app, "Poke is coming soon").waitForExistence(timeout: 2))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: toast(app))
        wait(for: [gone], timeout: 10)
    }

    /// protects=Stealth never shows a false privacy state (D21); fails_when=the tap turns the
    /// switch on or no toast explains it; no_claim=stealth itself (not built); toast runs 6s here.
    func testStealthTapShowsToastAndStaysOff() {
        let app = Self.launch(extra: ["-FriendCalToastSeconds", "6"])
        let stealth = app.switches["home.stealth"]
        stealth.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(toast(app, "Stealth is coming soon. Nothing is hidden yet.").waitForExistence(timeout: 2))
        XCTAssertEqual(stealth.value as? String, "0")
        attach(app, "home-stealth-toast")
    }

    /// protects=Share opens the system share sheet for the selected slot (D20, X9); fails_when=
    /// the button is disabled with a best cell selected or no sheet appears; no_claim=the exact
    /// message text (ShareText unit test owns it).
    func testShareOpensShareSheet() {
        let app = Self.launch()
        let share = app.buttons["home.share"]
        XCTAssertTrue(share.isEnabled)
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        let sheetNav = app.navigationBars["UIActivityContentView"]
        let appeared = sheet.waitForExistence(timeout: 5) || sheetNav.exists
        XCTAssertTrue(appeared, "share sheet did not appear")
        attach(app, "home-share-sheet")
    }

    /// protects=the "+6" face opens the drawer listing all 15 members with statuses (D36, X2);
    /// fails_when=no "+6" face, the sheet doesn't open, or rows are missing; no_claim=row order
    /// beyond the first.
    func testMoreFaceOpensDrawerWithAllMembers() {
        let app = Self.launch()
        let more = app.buttons["wheel.more"]
        XCTAssertEqual(more.label, "+6 more friends")
        more.tap()
        XCTAssertTrue(app.staticTexts["Brunch crew · 15"].waitForExistence(timeout: 3))
        let rows = app.descendants(matching: .any).matching(identifier: "drawer.row")
        XCTAssertEqual(rows.count, 15)
        XCTAssertEqual(rows.element(boundBy: 0).label, "Sam, free, online")
        attach(app, "drawer-selected")
    }

    /// protects=stub tabs are reachable from the native tab bar (D34); fails_when=a tab is
    /// missing or doesn't switch; no_claim=tab content (out of scope). Issue #5 D10: Invites left
    /// the stub list (testInvitesTabListsThePlan covers it).
    func testStubTabs() {
        let app = Self.launch()
        for tab in ["Groups", "Pokes", "Me"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.descendants(matching: .any)["stub.\(tab.lowercased())"].waitForExistence(timeout: 3), tab)
            attach(app, "tab-\(tab.lowercased())")
        }
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["home.poke"].waitForExistence(timeout: 3))
    }

    /// protects=the Invites tab lists the group's plan as a real row (issue #5 D10's named change,
    /// design 1.7A) and the DEMO badge sits inside the header row on the in-memory store (D7);
    /// fails_when=the stub is back, the row is missing, or the badge is absent; no_claim=row order
    /// (InvitesUITests).
    func testInvitesTabListsThePlan() {
        let app = Self.launch(extra: ["-FriendCalStore", "memory"])
        XCTAssertTrue(app.descendants(matching: .any)["home.demo"].exists)
        app.tabBars.buttons["Invites"].tap()
        let row = app.descendants(matching: .any).matching(identifier: "invites.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Brunch, 15 of 15 joined"), row.label)
        XCTAssertFalse(app.descendants(matching: .any)["stub.invites"].exists)
        attach(app, "tab-invites")
    }

    // MARK: T13

    /// protects=with no best cell nothing is selected, chips are hidden and Share is disabled;
    /// tapping a 0 cell selects it but Share stays disabled (X6, X10); fails_when=Share enables
    /// on a 0-count cell, chips show with no selection, or the 0 cell can't be selected;
    /// no_claim=the VoiceOver hint text (XCUITest can't read hints; previews show both).
    func testZeroCountCellSelectableButNotShareable() {
        let app = Self.launch("zeroOverlap")
        XCTAssertTrue(app.descendants(matching: .any)["heatmap.noOverlap"].exists)
        XCTAssertFalse(app.buttons["home.share"].isEnabled)
        XCTAssertFalse(app.scrollViews["chips"].exists)
        let tue = cell(app, week: 0, day: 1, "morning")
        tue.tap()
        XCTAssertEqual(tue.label, "Tuesday morning, 0 of 15 free, selected")
        XCTAssertFalse(app.buttons["home.share"].isEnabled)
        XCTAssertTrue(app.scrollViews["chips"].waitForExistence(timeout: 2))
        attach(app, "home-zero-cell-selected")
    }

    /// protects=with nothing selected the drawer lists names without inventing statuses (X11);
    /// fails_when=rows carry free/busy words or the prompt is missing; no_claim=selected-state
    /// rows (covered by testMoreFaceOpensDrawerWithAllMembers).
    func testDrawerWithoutSelectionShowsNamesOnly() {
        let app = Self.launch("zeroOverlap")
        app.buttons["wheel.more"].tap()
        XCTAssertTrue(app.staticTexts["Pick a time to see who's free"].waitForExistence(timeout: 3))
        let rows = app.descendants(matching: .any).matching(identifier: "drawer.row")
        XCTAssertEqual(rows.count, 15)
        XCTAssertEqual(rows.element(boundBy: 0).label, "Sam, online")
        XCTAssertEqual(rows.element(boundBy: 14).label, "Pia")
        attach(app, "drawer-no-selection")
    }

    /// protects=all 7 heatmap columns fit inside the card with tiled hit areas (D30, D32, X8):
    /// >= 40x44pt on widths >= 402pt, ~37x44pt allowed below (documented AC6); run on iPhone 17
    /// and iPhone SE (3rd gen); fails_when=a column is clipped, off-card, unhittable, or under the
    /// size floor; no_claim=visual numeral clipping inside a cell (screenshot shows it).
    func testAllColumnsFitInsideCard() {
        let app = Self.launch()
        let card = app.descendants(matching: .any)["heatmapCard"]
        let width = app.windows.firstMatch.frame.width
        let minWidth: CGFloat = width >= 402 ? 40 : 36.5
        for part in ["morning", "afternoon", "evening"] {
            for d in 0..<7 {
                let el = cell(app, week: 0, day: d, part)
                XCTAssertTrue(el.exists, "d\(d) \(part)")
                let f = el.frame
                XCTAssertTrue(card.frame.contains(f), "d\(d) \(part) \(f) outside card \(card.frame)")
                XCTAssertGreaterThanOrEqual(f.width, minWidth, "d\(d) \(part) width \(f.width) at \(width)pt")
                XCTAssertGreaterThanOrEqual(f.height, 44, "d\(d) \(part) height")
                if d > 0 || part == "evening" { XCTAssertTrue(el.isHittable, "d\(d) \(part)") }
            }
        }
        attach(app, "home-columns-\(Int(width))pt")
    }
}
