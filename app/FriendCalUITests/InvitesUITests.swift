import XCTest

/// The Invites tab and the create sheet (issue #5 PR1 acceptance 2, design DT4, DT6, DT12).
final class InvitesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private func rows(_ app: XCUIApplication) -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "invites.row") }

    /// protects=rows read title, status and Hosting, ordered locked-upcoming, requesting, past
    /// (dimmed) (design 1.7A, 7.2A), a row opens its invite and "+" opens the create sheet (1.6A);
    /// fails_when=the order or a status line changes, or a row opens nothing; no_claim=the 60% dim (screenshot).
    func testListOrderRowsAndEntries() {
        let app = LockedInviteUITests.launch("invites")
        app.tabBars.buttons["Invites"].tap()
        XCTAssertTrue(rows(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows(app).count, 4)
        let labels = (0..<4).map { rows(app).element(boundBy: $0).label }
        XCTAssertEqual(labels, [
            "Dinner, Locked · Sat, Nov 14 · 6:00–8:00 PM",
            "Brunch, 10 of 10 joined · Nov 9–23, hosting",
            "Hike, 5 of 6 joined · Oct 19–31, hosting, past",
            "Movie night, Locked · Tue, Oct 20 · 7:00–9:00 PM, past",
        ])
        attach(app, "invites-list")
        rows(app).element(boundBy: 0).tap()
        XCTAssertTrue(any(app, "invite.card").waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.firstMatch.identifier, "Invite")
        XCTAssertEqual(any(app, "invite.lockedTime").label, "6:00–8:00 PM")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(rows(app).firstMatch.waitForExistence(timeout: 5))
        app.buttons["invites.new"].tap()
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 5))
        app.buttons["create.cancel"].tap()
        XCTAssertTrue(rows(app).firstMatch.waitForExistence(timeout: 5))
    }

    /// protects=with no plans the tab shows "No invites yet" and "Start a plan" opens the create
    /// sheet (design 1.6A, 2.2A); fails_when=the empty state or its entry is missing; no_claim=copy beyond it.
    func testEmptyStateStartsAPlan() {
        let app = LockedInviteUITests.launch("noProposal")
        app.tabBars.buttons["Invites"].tap()
        XCTAssertTrue(any(app, "invites.empty").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No invites yet"].exists)
        attach(app, "invites-empty")
        app.buttons["invites.start"].tap()
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 5))
    }

    /// protects=Request times opens the create sheet with its defaults (title placeholder "Brunch",
    /// 8 people), Create reaches the success step with the deep link and a Share invite, and Done
    /// lands on the new invite in the Invites tab as the creator alone, with Home adopting the plan
    /// (D4, D13, design 3.2A, 3.3A, 5.4A); fails_when=creation fails on defaults, the link is
    /// missing, or Done lands on Home; no_claim=DatePicker validation (ProposalDraftTests), share
    /// sheet contents.
    func testCreateFromHomeLandsOnTheInvite() {
        let app = LockedInviteUITests.launch("noProposal", extra: PlacesUITests.lastCity(PlacesUITests.austinCity))
        app.buttons["heatmap.requestTimes"].tap()
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["create.title"].placeholderValue, "Brunch")
        XCTAssertEqual(app.buttons["create.city"].label, "City, Austin, TX", "the host's last city is prefilled (design 3.1A)")
        XCTAssertEqual(any(app, "create.expectedValue").label, "8")
        XCTAssertTrue(app.staticTexts["How many people, counting you?"].exists)
        let submit = app.buttons["create.submit"]
        XCTAssertTrue(submit.isEnabled, "defaults are valid")
        attach(app, "create-sheet")
        submit.tap()
        XCTAssertTrue(any(app, "create.success").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "create.success").label, "Brunch is live")
        XCTAssertTrue(any(app, "create.link").label.hasPrefix("https://friendcal.app/p/"))
        XCTAssertTrue(app.buttons["create.share"].exists)
        attach(app, "create-success")
        app.buttons["create.done"].tap()
        XCTAssertTrue(any(app, "invite.card").waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Invites"].isSelected)
        XCTAssertEqual(any(app, "invite.caption").label, "No one has joined yet")
        XCTAssertEqual(any(app, "invite.primary").label, "Invite friends")
        XCTAssertEqual(any(app, "invite.progress").label, "1 of 8 joined")
        attach(app, "invite-after-create")
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["of 8 free"].waitForExistence(timeout: 5), "Home adopted the new plan")
        XCTAssertFalse(app.buttons["heatmap.requestTimes"].exists)
    }

    /// protects=a store failure on create shows the mapped sentence inline with Retry and Details
    /// (design 2.3A) and the retry succeeds; fails_when=the error is a transient toast, lacks details,
    /// or the sheet closes; no_claim=real network failures (`-FriendCalFailNext` stands in).
    func testCreateFailureShowsInlineErrorWithDetailsAndRetries() {
        let app = LockedInviteUITests.launch("noProposal", extra: ["-FriendCalFailNext", "create"] + PlacesUITests.lastCity(PlacesUITests.austinCity))
        app.buttons["heatmap.requestTimes"].tap()
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 5))
        app.buttons["create.submit"].tap()
        XCTAssertTrue(any(app, "inlineError.message").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "inlineError.message").label, "Couldn't create the plan. Retry.")
        app.buttons["inlineError.details"].tap()
        XCTAssertTrue(any(app, "inlineError.detailsText").waitForExistence(timeout: 2))
        attach(app, "create-error")
        app.buttons["inlineError.retry"].tap()
        XCTAssertTrue(any(app, "create.success").waitForExistence(timeout: 5))
    }
}
