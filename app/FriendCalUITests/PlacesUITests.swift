import XCTest

/// Place voting on the Invite screen (#14): the host's city, the search sheet, the duplicate panel, the
/// search and picker failure sentences, and the places list. They run on the in-memory store with the
/// fixture search (`-FriendCalSearch fixture`), so nothing touches MapKit or the network; what real
/// MapKit returns is the device check (#12 criterion 10), not these tests.
/// Fixtures: the ten-person crew with Austin, TX as the city (design doc `docs/designs/friendcal-places.md`).
final class PlacesUITests: XCTestCase {
    /// `name|latitude|longitude`, the stored shape. Not JSON: UserDefaults drops a JSON-looking
    /// launch-argument value, so it would read back as no city.
    static let austinCity = "Austin, TX|30.2672|-97.7431"

    /// `-FriendCalLastCity` pins the remembered city for the launch (`none` is "no last city").
    static func lastCity(_ value: String) -> [String] { ["-FriendCalLastCity", value] }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    // MARK: Helpers

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Launches `fixture`, opens its invite from Home's heatmap header.
    private func openInvite(_ fixture: String, extra: [String] = []) -> XCUIApplication {
        let app = LockedInviteUITests.launch(fixture, extra: ["-FriendCalSearch", "fixture", "-FriendCalToastSeconds", "6"] + extra)
        app.buttons["heatmap.openInvite"].tap()
        XCTAssertTrue(any(app, "invite.card").waitForExistence(timeout: 5), "invite did not open")
        return app
    }

    /// The Places section sits below the first screen (design PL-1); swipe until `element` can be tapped.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        if !(element.exists && element.isHittable) {
            // Say what is on screen instead of just "not found": the failure is otherwise undiagnosable.
            let ids = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'places.' OR identifier BEGINSWITH 'invite.'"))
                .allElementsBoundByIndex.prefix(40).map { "\($0.identifier)@\($0.frame.integral)" }
            attach(app, "scroll-failure")
            XCTFail("could not scroll to \(element) (exists: \(element.exists)); on screen: \(ids.joined(separator: ", "))", file: file, line: line)
        }
    }

    private func type(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(field) did not appear")
        field.tap()
        field.typeText(text)
    }

    /// Visible texts and buttons (identifier or label), for failure messages only.
    private func screen(_ app: XCUIApplication) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(40).map { $0.identifier.isEmpty ? "\"\($0.label)\"" : $0.identifier }
        let buttons = app.buttons.allElementsBoundByIndex.prefix(40).map { $0.identifier.isEmpty ? "[\($0.label)]" : "[\($0.identifier)]" }
        let fields = app.textFields.allElementsBoundByIndex.map { "<\($0.identifier)>" }
        return "texts: \(texts.joined(separator: ", ")) | buttons: \(buttons.joined(separator: ", ")) | fields: \(fields.joined(separator: ", "))"
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: Host city (PL-5)

    /// protects=a host on a plan with no city sees the outlined "Choose a city" pill, tapping it opens
    /// Edit plan with the picker already pushed, picking a city returns to the form with it set, Save
    /// closes the sheet and the section becomes the empty state with the Suggest pill (R1: places need a
    /// city); fails_when=the pill is a stub toast, the picker is not pushed, the city does not reach the
    /// plan, or the pill stays; no_claim=MapKit city results (the fixture search stands in).
    func testHostChoosesACityFromThePlacesSection() {
        let app = openInvite("noCityHost", extra: Self.lastCity("none"))
        let choose = app.buttons["places.chooseCity"]
        scrollTo(choose, in: app)
        attach(app, "places-no-city-host")
        choose.tap()

        XCTAssertTrue(app.textFields["city.search.field"].waitForExistence(timeout: 5), "Edit plan opens with the picker pushed; \(screen(app))")
        XCTAssertEqual(any(app, "city.hint").label, "Type at least 2 letters")
        type("Aus", into: app.textFields["city.search.field"])
        let row = app.buttons["city.result"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Austin, TX"))
        attach(app, "city-picker-results")
        row.tap()

        let cityRow = app.buttons["create.city"]
        XCTAssertTrue(cityRow.waitForExistence(timeout: 5), "picking pops back to the form")
        XCTAssertEqual(cityRow.label, "City, Austin, TX")
        XCTAssertEqual(any(app, "create.cityCaption").label, "So friends can suggest places nearby.")
        app.buttons["create.submit"].tap()
        XCTAssertTrue(app.buttons["create.submit"].waitForNonExistence(timeout: 8), "Save closes the sheet; \(screen(app))")

        let suggest = app.buttons["places.suggest"]
        XCTAssertTrue(any(app, "invite.card").waitForExistence(timeout: 5), "Save closes the sheet")
        scrollTo(suggest, in: app)
        XCTAssertFalse(app.buttons["places.chooseCity"].exists, "the pill is gone once the plan has a city")
        XCTAssertTrue(any(app, "places.empty").exists)
        attach(app, "places-after-city")
    }

    /// protects=a friend on a plan with no city sees one muted line and no control (design PL-5);
    /// fails_when=a friend is offered the host's pill; no_claim=the host's name wording beyond Sam.
    func testFriendSeesNoCityLineAndNoPill() {
        let app = openInvite("noCity")
        let line = any(app, "places.noCity.friend")
        scrollTo(line, in: app)
        XCTAssertEqual(line.label, "Places open once Sam picks a city.")
        XCTAssertFalse(app.buttons["places.chooseCity"].exists)
        XCTAssertFalse(app.buttons["places.suggest"].exists)
    }

    /// protects=New plan needs a city: with none remembered the row reads "Choose a city" and Create is
    /// disabled, and picking one enables it (R1, design 3.1A); fails_when=Create works without a city or
    /// the picked city does not reach the row; no_claim=the created plan's contents (InvitesUITests).
    func testNewPlanNeedsACity() {
        let app = LockedInviteUITests.launch("noProposal", extra: ["-FriendCalSearch", "fixture"] + Self.lastCity("none"))
        app.buttons["heatmap.requestTimes"].tap()
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 5))
        let cityRow = app.buttons["create.city"]
        XCTAssertEqual(cityRow.label, "Choose a city")
        XCTAssertFalse(app.buttons["create.submit"].isEnabled, "Create needs a city")
        attach(app, "create-no-city")

        cityRow.tap()
        type("Dal", into: app.textFields["city.search.field"])
        let row = app.buttons["city.result"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(cityRow.waitForExistence(timeout: 5))
        XCTAssertEqual(cityRow.label, "City, Dallas, TX")
        XCTAssertTrue(app.buttons["create.submit"].isEnabled)

        // Value: protects=creating a plan remembers its city and the next New plan prefills it; fails_when=Create stops saving LastUsedCity or the prefill is not read; why_new=LastUsedCityTests covers the codec only, not the save on Create; seam=none; no_claim=Edit-plan saves
        app.buttons["create.submit"].tap()
        XCTAssertTrue(app.buttons["create.done"].waitForExistence(timeout: 8), "create succeeded; \(screen(app))")
        app.terminate()
        let again = LockedInviteUITests.launch("noProposal", extra: ["-FriendCalSearch", "fixture"])
        again.buttons["heatmap.requestTimes"].tap()
        XCTAssertTrue(again.buttons["create.city"].waitForExistence(timeout: 5))
        XCTAssertEqual(again.buttons["create.city"].label, "City, Dallas, TX", "the saved city prefills the next plan")
    }

    /// protects=the picker's two failure sentences, "No city found. Try another name." and the offline
    /// one, appear in place; fails_when=an empty or failed search shows nothing; no_claim=throttling copy
    /// (shared with the place search, below).
    func testCityPickerShowsItsFailureSentences() {
        let app = LockedInviteUITests.launch("noProposal", extra: ["-FriendCalSearch", "fixture", "-FriendCalSearchFailNext", "offline"] + Self.lastCity("none"))
        app.buttons["heatmap.requestTimes"].tap()
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 5))
        app.buttons["create.city"].tap()
        let field = app.textFields["city.search.field"]
        type("Aus", into: field)
        XCTAssertTrue(any(app, "city.error").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "city.error").label, "No connection. Check your internet and try again.")

        field.tap()
        field.typeText("zzz")
        let none = any(app, "city.error")
        let gone = expectation(for: NSPredicate(format: "label == %@", "No city found. Try another name."), evaluatedWith: none)
        wait(for: [gone], timeout: 5)
    }

    // MARK: Search (PL-4)

    /// protects=Suggest opens the search sheet with the prompt caption and the two-letter hint, a result
    /// is added in one tap, the sheet closes, the toast says "Added Juniper Table" and the section shows
    /// the place (design 1.5A, 2.2A, 7.1A); fails_when=the sheet stays, the toast is missing, or the place
    /// does not land; no_claim=real MapKit results.
    func testSuggestingAPlaceFromSearch() {
        let app = openInvite("placesEmpty")
        let suggest = app.buttons["places.suggest"]
        scrollTo(suggest, in: app)
        suggest.tap()

        let field = app.textFields["places.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "places.search.caption").label, "Within 25 km of Austin, TX")
        XCTAssertEqual(any(app, "places.search.hint").label, "Type at least 2 letters")
        attach(app, "search-empty")
        type("Juni", into: field)
        let row = app.buttons["places.search.result"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Juniper Table"))
        attach(app, "search-results")
        row.tap()

        XCTAssertTrue(any(app, "toast").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "toast").label, "Added Juniper Table")
        XCTAssertFalse(field.exists, "the sheet closed")
        XCTAssertEqual(any(app, "places.name").firstMatch.label, "Juniper Table")
    }

    /// protects=each search failure shows its approved sentence inside the sheet: nothing found, a
    /// result beyond 25 km (the R1 client guard), and offline; fails_when=an empty result shows nothing,
    /// the outside-area guard is skipped, or the sentence differs; no_claim=throttling (same path).
    func testSearchFailuresShowTheirSentences() {
        let app = openInvite("placesEmpty")
        let suggest = app.buttons["places.suggest"]
        scrollTo(suggest, in: app)
        suggest.tap()
        let field = app.textFields["places.search.field"]
        type("zzzz", into: field)
        let error = any(app, "places.search.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "No places found near Austin, TX. Try another name.")

        app.buttons["Clear search"].tap()
        field.typeText("Georgetown")
        let row = app.buttons["places.search.result"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let outside = expectation(for: NSPredicate(format: "label == %@", "That's outside Austin, TX. Try a place within 25 km."), evaluatedWith: error)
        wait(for: [outside], timeout: 5)
        attach(app, "search-outside-area")
    }

    /// protects=a one-shot offline failure shows the offline sentence; fails_when=a transport failure is
    /// swallowed; no_claim=recovery after reconnecting.
    func testOfflineSearchShowsTheOfflineSentence() {
        let app = openInvite("placesEmpty", extra: ["-FriendCalSearchFailNext", "offline"])
        let suggest = app.buttons["places.suggest"]
        scrollTo(suggest, in: app)
        suggest.tap()
        type("Juni", into: app.textFields["places.search.field"])
        let error = any(app, "places.search.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "No connection. Check your internet and try again.")
    }

    /// protects=a duplicate shows the inline panel in the same sheet, never a second one: someone
    /// else's place offers Vote (and moves the viewer's vote, with that toast), the viewer's own says "You
    /// already suggested this" (design 2.6B, 7.2A); fails_when=a duplicate is added twice, opens another
    /// sheet, or Vote does not vote; no_claim=the passed-place variant (PlaceBoardTests).
    func testDuplicateSuggestionShowsTheInlinePanel() {
        let app = openInvite("placesVoting")
        let suggest = app.buttons["places.suggest"]
        scrollTo(suggest, in: app)
        suggest.tap()
        let field = app.textFields["places.search.field"]
        type("Cafe Lola", into: field)
        let row = app.buttons["places.search.result"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let message = any(app, "places.duplicate.message")
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertEqual(message.label, "Already suggested by Maya")
        attach(app, "search-duplicate")

        // The viewer's own place reads differently.
        app.buttons["Clear search"].tap()
        field.typeText("Bluebonnet")
        let own = app.buttons["places.search.result"].firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 5))
        own.tap()
        let ownMessage = expectation(for: NSPredicate(format: "label == %@", "You already suggested this"), evaluatedWith: any(app, "places.duplicate.message"))
        wait(for: [ownMessage], timeout: 5)

        // And Vote on someone else's place moves the viewer's vote.
        app.buttons["Clear search"].tap()
        field.typeText("Cafe Lola")
        app.buttons["places.search.result"].firstMatch.tap()
        let vote = app.buttons["places.duplicate.vote"]
        XCTAssertTrue(vote.waitForExistence(timeout: 5))
        vote.tap()
        XCTAssertTrue(any(app, "toast").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "toast").label, "Moved your vote to Cafe Lola")
        XCTAssertFalse(field.exists, "the sheet closed")
    }

    // MARK: Caps and the list (PL-3)

    /// protects=a viewer at the personal cap sees the cap line instead of the Suggest pill (design 7.5A);
    /// fails_when=Suggest stays offered at the cap; no_claim=the plan-wide cap wording.
    func testPersonalCapReplacesTheSuggestPill() {
        let app = openInvite("placesCapped")
        let cap = any(app, "places.cap.personal")
        scrollTo(cap, in: app)
        XCTAssertEqual(cap.label, "You've suggested 2 places. Withdraw one to add another.")
        XCTAssertFalse(app.buttons["places.suggest"].exists)
    }

    /// protects=the host passes on a place from the list's menu (confirm names the votes that clear),
    /// the place moves to "Passed by host", and Bring back returns it (design 2.3A, 2.5A); fails_when=the
    /// row does not move, the confirm text drifts, or Bring back does nothing; no_claim=the server rules
    /// (the SQL lane) and the "Comes back with 0 votes" count.
    func testHostPassesOnAPlaceAndBringsItBack() {
        let app = openInvite("placesVetoed")
        let viewAll = app.buttons["places.viewAll"]
        scrollTo(viewAll, in: app)
        viewAll.tap()
        XCTAssertTrue(any(app, "places.list.passedHeader").waitForExistence(timeout: 5), "the fixture has a passed place; \(screen(app))")
        attach(app, "places-list-host")

        let menu = app.buttons["places.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["Pass on this place"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.label.hasPrefix("Pass on "), "confirm names the place: \(alert.label)")
        alert.buttons["Pass"].tap()
        let passedRows = app.descendants(matching: .any).matching(identifier: "places.vetoed.name")
        let two = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: passedRows)
        wait(for: [two], timeout: 5)

        app.buttons["places.bringBack"].firstMatch.tap()
        let back = expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: passedRows)
        wait(for: [back], timeout: 5)
        app.buttons["places.list.done"].tap()
    }

    // MARK: Pass 2 additions

    /// Value: protects=tapping the voted place's pill removes the vote with the "Vote removed" toast and tapping it again re-votes with "Voted for"; fails_when=the toggle or either toast copy breaks; why_new=only the duplicate-panel vote is UI-tested; seam=none; no_claim=server vote rules (SQL lane)
    func testVoteTogglesWithToasts() {
        let app = openInvite("placesVoting")
        let viewAll = app.buttons["places.viewAll"]
        scrollTo(viewAll, in: app)
        viewAll.tap()
        let voted = app.buttons.matching(identifier: "places.vote").matching(NSPredicate(format: "label CONTAINS 'Voted'")).firstMatch
        XCTAssertTrue(voted.waitForExistence(timeout: 5), "the viewer voted for one place; \(screen(app))")
        voted.tap()
        XCTAssertTrue(any(app, "toast").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "toast").label, "Vote removed")
        let none = expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: app.buttons.matching(identifier: "places.vote").matching(NSPredicate(format: "label CONTAINS 'Voted'")))
        wait(for: [none], timeout: 5)
        app.buttons["places.vote"].firstMatch.tap()
        let again = expectation(for: NSPredicate(format: "label BEGINSWITH 'Voted for '"), evaluatedWith: any(app, "toast"))
        wait(for: [again], timeout: 5)
    }

    /// Value: protects=Withdraw my place removes the viewer's own row, and a failed withdraw keeps it with an inline error; fails_when=withdraw does nothing, drops the row on failure, or shows no error; why_new=UI tests only see the cap line; seam=none; no_claim=the error sentence wording
    func testWithdrawOwnPlaceAndItsFailure() {
        let app = openInvite("placesCapped", extra: ["-FriendCalFailNext", "removePlace"])
        let viewAll = app.buttons["places.viewAll"]
        scrollTo(viewAll, in: app)
        viewAll.tap()
        let names = app.descendants(matching: .any).matching(identifier: "places.name")
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 5))
        let before = names.count
        func withdraw() {
            app.buttons["places.menu"].firstMatch.tap()
            app.buttons["Withdraw my place"].tap()
        }
        withdraw()
        XCTAssertTrue(any(app, "inlineError.message").waitForExistence(timeout: 5), "failure shows inline; \(screen(app))")
        XCTAssertEqual(names.count, before, "a failed withdraw keeps the row")
        withdraw()
        let gone = expectation(for: NSPredicate(format: "count == %d", before - 1), evaluatedWith: names)
        wait(for: [gone], timeout: 5)
    }

    /// Value: protects=Retry after a failed suggest replays that suggestion and lands the place; fails_when=Retry only clears the error (the dead-Retry bug), so no toast appears; why_new=no test taps Retry on the search sheet; seam=none; no_claim=the error sentence wording
    func testRetryAfterFailedSuggestResubmits() {
        let app = openInvite("placesEmpty", extra: ["-FriendCalFailNext", "suggestPlace"])
        let suggest = app.buttons["places.suggest"]
        scrollTo(suggest, in: app)
        suggest.tap()
        let field = app.textFields["places.search.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        type("Juni", into: field)
        let row = app.buttons["places.search.result"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let retry = any(app, "inlineError.retry")
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "the failed suggest shows Retry; \(screen(app))")
        retry.tap()
        XCTAssertTrue(any(app, "toast").waitForExistence(timeout: 5), "Retry replays the suggestion")
        XCTAssertEqual(any(app, "toast").label, "Added Juniper Table")
    }

    /// Value: protects=a picker search with no match shows "No city found. Try another name." on its own; fails_when=an empty or noResult search shows nothing; why_new=the existing picker test hits noResult only after a prior offline failure; seam=none; no_claim=MapKit
    func testCityPickerNoResultSentence() {
        let app = LockedInviteUITests.launch("noProposal", extra: ["-FriendCalSearch", "fixture", "-FriendCalSearchFailNext", "noResult"] + Self.lastCity("none"))
        app.buttons["heatmap.requestTimes"].tap()
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 5))
        app.buttons["create.city"].tap()
        type("zzz", into: app.textFields["city.search.field"])
        XCTAssertTrue(any(app, "city.error").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "city.error").label, "No city found. Try another name.")
    }

    /// Value: protects=a throttled place search shows "Searching too fast..." in the sheet; fails_when=throttling is swallowed or mapped to another sentence; why_new=the failure tests cover offline, noResult and outsideArea only; seam=none; no_claim=real MapKit throttling and retry timing
    func testThrottledSearchShowsItsSentence() {
        let app = openInvite("placesEmpty", extra: ["-FriendCalSearchFailNext", "throttled"])
        let suggest = app.buttons["places.suggest"]
        scrollTo(suggest, in: app)
        suggest.tap()
        type("Juni", into: app.textFields["places.search.field"])
        let error = any(app, "places.search.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "Searching too fast. Wait a moment and try again.")
    }
}
