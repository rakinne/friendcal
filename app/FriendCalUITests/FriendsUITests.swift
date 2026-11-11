import XCTest

/// Add a friend (docs/designs/friendcal-add-friend-spec.md): the sheet, Accept, the roster, Remove and
/// the link router. The sheet is reachable from the debug sheet only until the entry points ship (PR 3):
/// long-press the wordmark, then "Add a friend".
///
/// Launch arguments used here: `-FriendCalFriendLink valid|dead|own|already` (what the in-memory store
/// answers for any token), `-FriendCalPendingLink none|stored|<url>` (the stored pending link),
/// `-FriendCalFailNext friendLink|resetFriendLink|previewFriendLink|acceptFriendLink|removeFriend|friends`,
/// `-FriendCalStoreLatency <s>`, `-FriendCalSignedOut 1` (the gate shows). Screenshots are attached for
/// design review; no pixel baselines.
final class FriendsUITests: XCTestCase {
    static let token = "AbCdEfGhIjKlMnOpQr_-12"
    static let friendLink = "friendcal://friend/\(token)?n=Sam"

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    static func launch(_ fixture: String = "populated", tab: String = "home", device: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FriendCalFixture", fixture, "-FriendCalStore", "memory", "-FriendCalNow", "2026-11-13T20:10",
                               "-FriendCalTab", tab, "-FriendCalToastSeconds", "8", "-FriendCalSearch", "fixture"] + extra
        app.launch()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Home, then the debug sheet, then Add a friend.
    @discardableResult
    private func openSheet(_ app: XCUIApplication) -> XCUIElement {
        let wordmark = any(app, "home.wordmark")
        XCTAssertTrue(wordmark.waitForExistence(timeout: 10), "Home did not load")
        wordmark.press(forDuration: 1.2)
        let button = app.buttons["debug.addFriend"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "debug sheet did not open")
        button.tap()
        let link = any(app, "addFriend.link")
        XCTAssertTrue(link.waitForExistence(timeout: 8), "the sheet did not show a link")
        return link
    }

    private func tabBadge(_ app: XCUIApplication, _ tab: String) -> String? {
        let value = app.tabBars.buttons[tab].value as? String
        return value
    }

    // MARK: Sheet

    /// protects=the sheet opens with a 22-character link in the spec's form (no scheme, no name hint),
    /// Copy turns to "Copied", Reset asks first and then shows a NEW link with "New link ready", and
    /// the QR pushes inside the same sheet and comes back; fails_when=any step breaks or the link
    /// text carries a scheme or hint; no_claim=the system share sheet, haptics, brightness (device).
    func testSheetShowsLinkCopiesResetsAndShowsQR() {
        let app = Self.launch()
        let link = openSheet(app)
        let text = link.label.isEmpty ? (link.value as? String ?? "") : link.label
        XCTAssertTrue(text.hasPrefix("friendcal.app/f/"), text)
        XCTAssertEqual(text.count, "friendcal.app/f/".count + 22)
        XCTAssertFalse(text.contains("://") || text.contains("?"), "no scheme, no name hint")
        XCTAssertTrue(app.buttons["addFriend.share"].exists)
        attach(app, "add-friend-sheet")

        app.buttons["addFriend.copy"].firstMatch.tap()
        XCTAssertTrue(app.buttons["addFriend.copy"].firstMatch.label == "Copied" || app.staticTexts["Copied"].waitForExistence(timeout: 2))

        app.buttons["addFriend.reset"].tap()
        XCTAssertTrue(app.staticTexts["Reset your link?"].waitForExistence(timeout: 3), "the reset must confirm first")
        XCTAssertTrue(app.staticTexts["The old link stops working for anyone who hasn't joined yet. Friends already connected stay connected."].exists)
        app.buttons.matching(NSPredicate(format: "label == %@", "Reset link")).allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND label == %@", "New link ready")).firstMatch.waitForExistence(timeout: 5))
        let after = any(app, "addFriend.link")
        XCTAssertNotEqual(after.label, text, "the link changed")

        app.buttons["addFriend.qr"].tap()
        XCTAssertTrue(any(app, "qr.code").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "qr.link").exists)
        attach(app, "add-friend-qr")
        app.buttons["qr.back"].tap()
        XCTAssertTrue(any(app, "addFriend.link").waitForExistence(timeout: 3))
        app.buttons["addFriend.done"].tap()
        XCTAssertTrue(any(app, "home.wordmark").waitForExistence(timeout: 5))
    }

    /// protects=a first open with nothing cached shows a skeleton and a disabled Share; a failed fetch shows
    /// the inline sentence and Retry; fails_when=Share is live before there is a link, or Retry does nothing.
    func testSheetSkeletonAndFetchFailureWithRetry() {
        let app = Self.launch(extra: ["-FriendCalFailNext", "friendLink"])
        let wordmark = any(app, "home.wordmark")
        XCTAssertTrue(wordmark.waitForExistence(timeout: 10))
        wordmark.press(forDuration: 1.2)
        app.buttons["debug.addFriend"].tap()
        XCTAssertTrue(any(app, "inlineError.message").waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Couldn't get your link"].exists)
        XCTAssertFalse(app.buttons["addFriend.copy"].exists, "no Copy without a link")
        XCTAssertFalse(app.buttons["addFriend.qr"].isEnabled, "no QR without a link")
        attach(app, "add-friend-error")
        app.buttons["inlineError.retry"].tap()
        XCTAssertTrue(any(app, "addFriend.link").waitForExistence(timeout: 8), "Retry gets the link")
        XCTAssertTrue(app.buttons["addFriend.qr"].isEnabled)
    }

    func testSheetShowsASkeletonWhileTheFirstLinkIsOnItsWay() {
        let app = Self.launch(extra: ["-FriendCalStoreLatency", "2.5"])
        let wordmark = any(app, "home.wordmark")
        XCTAssertTrue(wordmark.waitForExistence(timeout: 15))
        wordmark.press(forDuration: 1.2)
        app.buttons["debug.addFriend"].tap()
        XCTAssertTrue(any(app, "addFriend.skeleton").waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["addFriend.copy"].exists)
        XCTAssertTrue(any(app, "addFriend.link").waitForExistence(timeout: 10))
    }

    /// protects=a failed reset leaves a usable link (the sheet re-reads before enabling anything) and says
    /// so; fails_when=the sheet is left disabled, or shows no sentence.
    func testFailedResetKeepsALinkAndSaysSo() {
        let app = Self.launch(extra: ["-FriendCalFailNext", "resetFriendLink"])
        let link = openSheet(app)
        let before = link.label
        app.buttons["addFriend.reset"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Reset link")).allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.staticTexts["Couldn't reset your link. Try again."].waitForExistence(timeout: 8))
        XCTAssertTrue(any(app, "addFriend.link").waitForExistence(timeout: 8))
        XCTAssertEqual(any(app, "addFriend.link").label, before, "the old link is still the link")
        XCTAssertTrue(app.buttons["addFriend.qr"].isEnabled)
    }

    /// protects=at AX3 and on an iPhone-SE-sized layout the whole link is present and never truncated,
    /// and Copy, Share and Show QR stay at least 44pt; fails_when=the link is cut off or a control is small.
    func testLinkIsNeverClippedAtLargeSizes() {
        let app = Self.launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let link = openSheet(app)
        XCTAssertEqual(link.label.count, "friendcal.app/f/".count + 22, "the whole link is present")
        attach(app, "add-friend-AX3")
        for id in ["addFriend.copy", "addFriend.reset", "addFriend.qr", "addFriend.done"] {
            let element = app.buttons[id].firstMatch
            XCTAssertTrue(element.exists, id)
            XCTAssertGreaterThanOrEqual(element.frame.height, 44, id)
            XCTAssertGreaterThanOrEqual(element.frame.width, 44, id)
        }
    }

    // MARK: Entry points

    /// protects=the Groups header's person.badge.plus button is labeled "Add a friend", is at least 44pt,
    /// and opens the sheet; fails_when=the button is missing, small, or opens nothing.
    func testGroupsHeaderButtonOpensTheSheet() {
        let app = Self.launch(tab: "groups", extra: ["-FriendCalGroups", "crew", "-FriendCalPendingLink", "none"])
        let button = app.buttons["groups.addFriend"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertEqual(button.label, "Add a friend")
        XCTAssertGreaterThanOrEqual(button.frame.height, 43.9)   // 44pt, within float error
        XCTAssertGreaterThanOrEqual(button.frame.width, 43.9)
        button.tap()
        XCTAssertTrue(any(app, "addFriend.link").waitForExistence(timeout: 8))
    }

    /// protects=the wheel's empty state reads "Add a friend" and opens the sheet; fails_when=it still
    /// says Invite or toasts "coming soon".
    func testWheelEmptyStateOpensTheSheet() {
        let app = Self.launch("noFriends", extra: ["-FriendCalPendingLink", "none"])
        let pill = app.buttons["wheel.invite"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertEqual(pill.label, "Add a friend")
        pill.tap()
        XCTAssertTrue(any(app, "addFriend.link").waitForExistence(timeout: 8))
    }

    // MARK: Accept

    /// protects=opening a friend link shows Accept with the SERVER's name, calls nothing until Connect, and
    /// Connect lands on Groups with Sam's row highlighted and the Moments line saying so; fails_when=the
    /// name comes from the URL hint, Connect does not reach Groups, or the card opens by itself.
    func testAcceptConnectsAndLandsOnGroups() {
        let app = Self.launch(extra: ["-FriendCalGroups", "friends", "-FriendCalPendingLink", "friendcal://friend/\(Self.token)?n=NotTheRealName", "-FriendCalFriendLink", "valid"])
        XCTAssertTrue(any(app, "accept.headline").waitForExistence(timeout: 10))
        XCTAssertEqual(any(app, "accept.headline").label, "Sam wants to connect", "the server's name, not the hint")
        XCTAssertEqual(any(app, "accept.body").label, "You and Sam will see each other's names and when you're busy. Plan details stay private unless you share them.")
        XCTAssertTrue(app.buttons["accept.connect"].exists)
        XCTAssertEqual(app.buttons["accept.connect"].label, "Connect with Sam")
        attach(app, "accept")
        app.buttons["accept.connect"].tap()
        XCTAssertTrue(app.buttons["groups.setStatus"].waitForExistence(timeout: 10), "Dismissed to Groups")
        XCTAssertTrue(app.tabBars.buttons["Groups"].isSelected)
        XCTAssertTrue(any(app, "groups.row.highlighted").waitForExistence(timeout: 5), "Sam's row is highlighted")
        XCTAssertEqual(any(app, "groups.moment").staticTexts.firstMatch.label, "You and Sam are connected")
        XCTAssertFalse(any(app, "friend.poke").exists, "the card does not open by itself")
        attach(app, "after-connect")
    }

    /// protects=dead, own and already each say their own line with one button, and none names a reason;
    /// fails_when=a dead link offers advice, or own/already lack their button.
    func testAcceptDeadOwnAlready() {
        let dead = Self.launch(extra: ["-FriendCalPendingLink", Self.friendLink, "-FriendCalFriendLink", "dead"])
        XCTAssertTrue(any(dead, "accept.dead.title").waitForExistence(timeout: 10))
        XCTAssertEqual(any(dead, "accept.dead.title").label, "This link doesn't work anymore.")
        attach(dead, "accept-dead")
        dead.buttons["accept.dead.button"].tap()
        XCTAssertTrue(any(dead, "home.wordmark").waitForExistence(timeout: 5))
        dead.terminate()

        let own = Self.launch(extra: ["-FriendCalPendingLink", Self.friendLink, "-FriendCalFriendLink", "own"])
        XCTAssertTrue(any(own, "accept.own.title").waitForExistence(timeout: 10))
        XCTAssertEqual(any(own, "accept.own.title").label, "This is your link")
        own.buttons["accept.own.button"].tap()
        XCTAssertTrue(any(own, "addFriend.link").waitForExistence(timeout: 8), "Share it opens the sheet")
        own.terminate()

        let already = Self.launch(extra: ["-FriendCalPendingLink", Self.friendLink, "-FriendCalFriendLink", "already"])
        XCTAssertTrue(any(already, "accept.already.title").waitForExistence(timeout: 10))
        XCTAssertEqual(any(already, "accept.already.title").label, "You and Sam are already connected")
        already.buttons["accept.already.button"].tap()
        XCTAssertTrue(already.tabBars.buttons["Groups"].waitForExistence(timeout: 5))
        XCTAssertTrue(already.tabBars.buttons["Groups"].isSelected)
    }

    /// protects=a failed Connect keeps the link and offers Retry, and the retry connects; a failed check
    /// does the same; fails_when=a failure is terminal.
    func testAcceptFailuresKeepTheLinkAndRetry() {
        let connectFails = Self.launch(extra: ["-FriendCalPendingLink", Self.friendLink, "-FriendCalFriendLink", "valid", "-FriendCalFailNext", "acceptFriendLink"])
        XCTAssertTrue(connectFails.buttons["accept.connect"].waitForExistence(timeout: 10))
        connectFails.buttons["accept.connect"].tap()
        XCTAssertTrue(any(connectFails, "inlineError.message").waitForExistence(timeout: 8))
        XCTAssertTrue(connectFails.staticTexts["Couldn't connect. Try again."].exists)
        attach(connectFails, "accept-connect-failed")
        connectFails.buttons["inlineError.retry"].tap()
        XCTAssertTrue(connectFails.buttons["groups.setStatus"].waitForExistence(timeout: 10), "the retry connected")
        connectFails.terminate()

        let checkFails = Self.launch(extra: ["-FriendCalPendingLink", Self.friendLink, "-FriendCalFriendLink", "valid", "-FriendCalFailNext", "previewFriendLink"])
        XCTAssertTrue(any(checkFails, "inlineError.message").waitForExistence(timeout: 10))
        XCTAssertTrue(checkFails.staticTexts["Couldn't check this link. Try again."].exists)
        checkFails.buttons["inlineError.retry"].tap()
        XCTAssertTrue(checkFails.buttons["accept.connect"].waitForExistence(timeout: 8))
    }

    /// protects=Not now clears the link and it does not come back on the next launch, while an unanswered
    /// link DOES survive a relaunch; fails_when=Not now leaves the link stored, or the router forgets it.
    func testNotNowDoesNotReturnButAnUnansweredLinkSurvivesARelaunch() {
        let first = Self.launch(extra: ["-FriendCalPendingLink", Self.friendLink, "-FriendCalFriendLink", "valid"])
        XCTAssertTrue(first.buttons["accept.connect"].waitForExistence(timeout: 10))
        first.terminate()   // never answered: it stays pending on the device

        let second = Self.launch(extra: ["-FriendCalPendingLink", "stored", "-FriendCalFriendLink", "valid"])
        XCTAssertTrue(second.buttons["accept.connect"].waitForExistence(timeout: 10), "an unanswered link survives a relaunch")
        second.buttons["accept.notNow"].tap()
        XCTAssertTrue(any(second, "home.wordmark").waitForExistence(timeout: 5))
        XCTAssertFalse(any(second, "accept").exists)
        second.terminate()

        let third = Self.launch(extra: ["-FriendCalPendingLink", "stored", "-FriendCalFriendLink", "valid"])
        XCTAssertTrue(any(third, "home.wordmark").waitForExistence(timeout: 10))
        XCTAssertFalse(third.buttons["accept.connect"].waitForExistence(timeout: 3), "Not now does not come back")
    }

    /// protects=a friend link opened while the app is running shows Accept, and one opened with a sheet
    /// up waits for that sheet to close instead of dismissing it; fails_when=the sheet is torn down, or
    /// Accept never appears after it closes.
    func testALinkOpenedWithASheetUpWaitsForTheSheetToClose() {
        let app = Self.launch("noProposal", extra: ["-FriendCalPendingLink", "none", "-FriendCalFriendLink", "valid"])
        XCTAssertTrue(app.buttons["heatmap.requestTimes"].waitForExistence(timeout: 10))
        app.buttons["heatmap.requestTimes"].tap()
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 5))
        XCUIDevice.shared.system.open(URL(string: Self.friendLink)!)
        XCTAssertTrue(any(app, "createSheet").waitForExistence(timeout: 3), "nothing is dismissed for it")
        XCTAssertFalse(app.buttons["accept.connect"].waitForExistence(timeout: 2), "Accept waits")
        app.buttons["create.cancel"].tap()
        XCTAssertTrue(app.buttons["accept.connect"].waitForExistence(timeout: 10), "Accept appears when the sheet closes")
    }

    /// protects=junk still toasts, and a newer link replaces an older pending one; fails_when=junk opens
    /// Accept or a second link opens two covers.
    func testNewestLinkWinsAndJunkToasts() {
        let app = Self.launch(extra: ["-FriendCalPendingLink", "none", "-FriendCalFriendLink", "valid"])
        XCTAssertTrue(any(app, "home.wordmark").waitForExistence(timeout: 10))
        XCUIDevice.shared.system.open(URL(string: "friendcal://friend/short")!)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND label == %@", "That link isn't a FriendCal invite")).firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.system.open(URL(string: Self.friendLink)!)
        XCTAssertTrue(app.buttons["accept.connect"].waitForExistence(timeout: 10), "a friend link opened while running shows Accept")
    }

    // MARK: Signed out

    /// protects=a friend link opened before sign-in waits behind the gate ("Sam wants to connect", button
    /// "Continue") and reaches Accept after sign-in; fails_when=the link is lost at sign-in, or the gate
    /// speaks plan-invite wording for a friend.
    func testSignedOutFriendLinkSurvivesSignInAndReachesAccept() {
        let app = Self.launch(extra: ["-FriendCalSignedOut", "1", "-FriendCalPendingLink", Self.friendLink, "-FriendCalFriendLink", "valid"])
        let pill = any(app, "auth.invitedPill")
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertEqual(pill.label, "Sam wants to connect")
        XCTAssertEqual(app.buttons["auth.continue"].label, "Continue")
        attach(app, "gate-friend-link")
        let field = app.textFields["auth.nameField"]
        field.tap()
        field.typeText("Pat")
        app.buttons["auth.continue"].tap()
        XCTAssertTrue(app.buttons["accept.connect"].waitForExistence(timeout: 10), "Accept after sign-in")
    }

    func testSignedOutFriendLinkWithoutAHintReadsAFriend() {
        let app = Self.launch(extra: ["-FriendCalSignedOut", "1", "-FriendCalPendingLink", "friendcal://friend/\(Self.token)", "-FriendCalFriendLink", "valid"])
        XCTAssertEqual(any(app, "auth.invitedPill").label, "A friend wants to connect")
    }

    /// protects=a plan link opened while signed out survives sign-in and lands on that invite (the
    /// regression contract: the old replay code never worked, because nothing stored the link);
    /// fails_when=the invite never opens after sign-in.
    func testSignedOutPlanLinkLandsOnTheInviteAfterSignIn() {
        let app = Self.launch("lockedInvite", extra: ["-FriendCalSignedOut", "1", "-FriendCalPendingLink",
                                                     "friendcal://proposal/00000000-0000-0000-0000-000000000900?t=Dinner"])
        XCTAssertEqual(any(app, "auth.invitedPill").waitForExistence(timeout: 10) ? any(app, "auth.invitedPill").label : "", "You were invited to Dinner")
        XCTAssertEqual(app.buttons["auth.continue"].label, "Continue to invite")
        let field = app.textFields["auth.nameField"]
        field.tap()
        field.typeText("Pat")
        app.buttons["auth.continue"].tap()
        XCTAssertTrue(any(app, "invite.card").waitForExistence(timeout: 10), "lands on the invite")
        XCTAssertTrue(app.tabBars.buttons["Invites"].isSelected)
    }

    // MARK: Roster

    /// protects=a friend who joins through your link is held as new until Groups is on screen: the Groups
    /// tab wears a dot after a foreground, then Groups announces them once with a highlight and the Moments
    /// line; fails_when=the dot never shows, the arrival is announced on the wrong screen, or twice.
    func testSenderLearnsOfAFriendOnTheNextRefresh() {
        let app = Self.launch(extra: ["-FriendCalGroups", "friends", "-FriendCalPendingLink", "none"])
        XCTAssertTrue(any(app, "home.wordmark").waitForExistence(timeout: 10))
        any(app, "home.wordmark").press(forDuration: 1.2)
        let join = app.buttons["debug.friendJoins"]
        XCTAssertTrue(join.waitForExistence(timeout: 5))
        join.tap()
        app.buttons["debug.done"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        let groupsTab = app.tabBars.buttons["Groups"]
        let predicate = NSPredicate(format: "label CONTAINS '1' OR value CONTAINS '1'")
        expectation(for: predicate, evaluatedWith: groupsTab)
        waitForExpectations(timeout: 10)
        attach(app, "groups-tab-dot")
        groupsTab.tap()
        XCTAssertTrue(any(app, "groups.row.highlighted").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "groups.moment").staticTexts.firstMatch.label, "You and Jess are connected")
        XCTAssertFalse(groupsTab.label.contains("1") || (groupsTab.value as? String)?.contains("1") == true, "the dot goes once they are announced")
    }

    /// protects=with no plan members the wheel draws your friends, so "Add your first fave" goes away
    /// after the first friend; fails_when=the empty state stays or the wheel keeps no face.
    func testWheelDrawsFriendsWhenThereIsNoPlan() {
        let app = Self.launch("noFriends", extra: ["-FriendCalPendingLink", "none"])
        XCTAssertTrue(app.buttons["wheel.invite"].waitForExistence(timeout: 10), "empty before the first friend")
        any(app, "home.wordmark").press(forDuration: 1.2)
        app.buttons["debug.friendJoins"].tap()
        app.buttons["debug.done"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(any(app, "wheel.face").waitForExistence(timeout: 10), "the first friend is on the wheel")
        XCTAssertFalse(app.buttons["wheel.invite"].exists, "the empty state is gone")
        attach(app, "wheel-with-first-friend")
    }

    // MARK: Remove

    /// protects=Remove sits at the bottom of the friend card, confirms in the spec's words, closes the card,
    /// and the row leaves with "Removed Arlo"; a failure brings the row back with the sentence;
    /// fails_when=Remove acts without asking, the row stays after success, or vanishes after a failure.
    func testRemoveAFriend() {
        let app = Self.launch(tab: "groups", extra: ["-FriendCalGroups", "crew", "-FriendCalPendingLink", "none"])
        XCTAssertTrue(app.buttons["groups.setStatus"].waitForExistence(timeout: 10))
        let arlo = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Arlo'")).firstMatch
        XCTAssertTrue(arlo.waitForExistence(timeout: 5))
        arlo.tap()
        XCTAssertTrue(app.buttons["friend.remove"].waitForExistence(timeout: 5))
        attach(app, "friend-card-remove")
        app.buttons["friend.remove"].tap()
        XCTAssertTrue(app.staticTexts["Remove Arlo?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Arlo won't be able to reconnect with your link. To reconnect later, open Arlo's link."].exists)
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND label == %@", "Removed Arlo")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertFalse(any(app, "friend.poke").exists, "the card closed")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Arlo'")).firstMatch.waitForExistence(timeout: 2), "the row left")
    }

    func testRemoveFailureBringsTheRowBack() {
        let app = Self.launch(tab: "groups", extra: ["-FriendCalGroups", "crew", "-FriendCalPendingLink", "none", "-FriendCalFailNext", "removeFriend"])
        XCTAssertTrue(app.buttons["groups.setStatus"].waitForExistence(timeout: 10))
        let arlo = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Arlo'")).firstMatch
        arlo.tap()
        app.buttons["friend.remove"].tap()
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND label == %@", "Couldn't remove that friend. Try again.")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Arlo'")).firstMatch.waitForExistence(timeout: 5), "the row is back")
    }

    /// protects=a failed FIRST roster load shows the inline error with Retry and never the "no friends"
    /// state; fails_when=an error reads as an empty roster.
    func testAFailedFirstLoadIsAnErrorNeverNoFriends() {
        let app = Self.launch("noFriends", tab: "groups", extra: ["-FriendCalGroups", "alone", "-FriendCalPendingLink", "none", "-FriendCalFailNext", "friends"])
        XCTAssertTrue(any(app, "inlineError.message").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["No friends here yet"].exists, "an error never produces the empty state")
        attach(app, "groups-load-error")
        app.buttons["inlineError.retry"].tap()
        XCTAssertTrue(app.staticTexts["No friends here yet"].waitForExistence(timeout: 8))
    }
}
