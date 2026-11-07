import XCTest

/// The recipient loop on the in-memory store (issue #5 PR1 acceptance 1-3, design DT1-DT5, DT12).
/// Fixtures: `-FriendCalFixture <scenario> -FriendCalStore memory`; the clock is pinned with
/// `-FriendCalNow` so past cells and the invite's dates are deterministic (week 1 is Nov 9-15 2026).
/// Screenshots are attached for /ios-design-review; there are no pixel baselines.
final class LockedInviteUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    static func launch(_ fixture: String, now: String = "2026-11-06T12:00", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FriendCalFixture", fixture, "-FriendCalStore", "memory", "-FriendCalNow", now] + extra
        app.launch()
        XCTAssertTrue(app.buttons["home.poke"].waitForExistence(timeout: 10), "Home did not load")
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Home's heatmap header links to the invite (design 1.1A).
    @discardableResult
    private func openInvite(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["heatmap.openInvite"].tap()
        let card = any(app, "invite.card")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "invite did not open")
        return card
    }

    private func markCell(_ app: XCUIApplication, week: Int = 0, day: Int, _ part: String) -> XCUIElement {
        app.descendants(matching: .any)["mark.w\(week).d\(day).\(part)"]
    }

    /// Waits for `el.label == label`; on timeout the failure names what the element reads instead
    /// (and any toast on screen), so a wrong state is diagnosable from the log.
    private func waitForLabel(_ el: XCUIElement, _ label: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let ok = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: el)
        if XCTWaiter().wait(for: [ok], timeout: timeout) != .completed {
            let app = XCUIApplication()
            let toast = app.staticTexts["toast"]
            XCTFail("expected \"\(label)\", got \(el.exists ? "\"\(el.label)\"" : "<missing>")\(toast.exists ? "; toast: \"\(toast.label)\"" : "")", file: file, line: line)
        }
    }

    // MARK: Acceptance 1: recipient loop

    /// protects=the caption is derived ("Locked until 1 more friend overlaps" for 7 of 10, not a
    /// hardcoded 8), Unlock opens the availability sheet, tapping the best cell reaches quorum
    /// ("Waiting for Sam to lock."), a second tap releases it, and the invite's "you're free" line and
    /// link copy follow the holds (D1, D9, C3, design 1.1A, 3.1A); fails_when=any stage stops moving
    /// the next; no_claim=network convergence (the in-memory store stands in), haptics.
    func testRecipientUnlocksReachesQuorumAndReleases() {
        let app = Self.launch("lockedInvite")
        openInvite(app)
        XCTAssertEqual(app.navigationBars.firstMatch.identifier, "Locked Invite")
        XCTAssertEqual(any(app, "invite.caption").label, "Locked until 1 more friend overlaps")
        XCTAssertEqual(any(app, "invite.progress").label, "7 of 10 overlap so far")
        XCTAssertFalse(any(app, "invite.primary").exists, "a recipient has no coral control")
        let unlock = app.buttons["invite.unlock"]
        XCTAssertEqual(unlock.label, "Unlock with availability")
        attach(app, "invite-requesting")

        unlock.tap()
        XCTAssertTrue(app.buttons["availability.done"].waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "availability.caption").label, "Locked until 1 more friend overlaps")
        let sat = markCell(app, day: 5, "afternoon")
        XCTAssertEqual(sat.label, "Saturday afternoon, 7 of 10 free, best, not marked")
        attach(app, "availability-sheet")
        sat.tap()
        waitForLabel(sat, "Saturday afternoon, 8 of 10 free, best, you're free here")
        waitForLabel(any(app, "availability.caption"), "Enough friends overlap. Waiting for Sam to lock.")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Cleo, free")).firstMatch.exists, "chips follow the tapped cell")
        attach(app, "availability-marked")
        sat.tap()
        waitForLabel(sat, "Saturday afternoon, 7 of 10 free, best, not marked")
        waitForLabel(any(app, "availability.caption"), "Locked until 1 more friend overlaps")
        sat.tap()
        waitForLabel(sat, "Saturday afternoon, 8 of 10 free, best, you're free here")

        app.buttons["availability.done"].tap()
        XCTAssertTrue(any(app, "invite.free").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "invite.free").label, "You're free Sat afternoon")
        XCTAssertEqual(app.buttons["invite.unlock"].label, "Update your availability")
        XCTAssertEqual(any(app, "invite.caption").label, "Enough friends overlap. Waiting for Sam to lock.")
        XCTAssertEqual(any(app, "invite.progress").label, "8 of 10 overlap so far")
        attach(app, "invite-quorum-recipient")
    }

    /// protects=past cells in the availability sheet are quiet: no button trait, a "passed" label and
    /// a tap that changes nothing (D9, design 5.2A); cells outside the window stay distinct;
    /// fails_when=a past cell can be marked or reads as a button; no_claim=the surface2 fill (screenshot).
    func testPastCellsAreQuietInMarkMode() {
        let app = Self.launch("lockedInvite", now: "2026-11-10T12:00")
        openInvite(app)
        app.buttons["invite.unlock"].tap()
        XCTAssertTrue(app.buttons["availability.done"].waitForExistence(timeout: 5))
        let tueMorning = markCell(app, day: 1, "morning")
        XCTAssertEqual(tueMorning.label, "Tuesday morning, already passed")
        XCTAssertFalse(app.buttons["mark.w0.d1.morning"].exists, "a past cell is not a button")
        XCTAssertEqual(markCell(app, day: 0, "morning").label, "Monday morning, outside the proposal window")
        let tueAfternoon = markCell(app, day: 1, "afternoon")
        XCTAssertTrue(tueAfternoon.label.hasSuffix("not marked"))
        tueMorning.tap()
        XCTAssertEqual(tueMorning.label, "Tuesday morning, already passed")
        XCTAssertEqual(any(app, "availability.caption").label, "Locked until 1 more friend overlaps")
        attach(app, "availability-past-cells")
    }

    /// protects=every mark-mode cell is >= 44 x 44pt inside the sheet (design 6.1A; run on iPhone 17
    /// and iPhone SE 3rd gen) and the week pager carries over; fails_when=the gutter returns or a cell
    /// shrinks; no_claim=visual numeral clipping (screenshot).
    func testMarkModeCellsAreAtLeast44pt() {
        let app = Self.launch("lockedInvite")
        openInvite(app)
        app.buttons["invite.unlock"].tap()
        XCTAssertTrue(app.buttons["availability.done"].waitForExistence(timeout: 5))
        let card = any(app, "markCard")
        let width = app.windows.firstMatch.frame.width
        for part in ["morning", "afternoon", "evening"] {
            for d in 0..<7 {
                let el = markCell(app, day: d, part)
                XCTAssertTrue(el.exists, "d\(d) \(part)")
                let f = el.frame
                XCTAssertTrue(card.frame.contains(f), "d\(d) \(part) \(f) outside card \(card.frame)")
                XCTAssertGreaterThanOrEqual(f.width, 44, "d\(d) \(part) width \(f.width) at \(width)pt")
                XCTAssertGreaterThanOrEqual(f.height, 44, "d\(d) \(part) height")
            }
        }
        XCTAssertTrue(any(app, "heatmap.pageIndicator").exists)
        attach(app, "availability-cells-\(Int(width))pt")
    }

    // MARK: Acceptance 3: creator locks

    /// protects=the creator at quorum gets the Lock pill, the lock sheet defaults to 2 h with the
    /// window and attendees, locking settles the invite (nav title, badge, date + window, "You're
    /// in", "8 of 10 are in") and Home shows the locked cell with "in" chips and an enabled Share
    /// (D14, C1, design 1.1A, 2.1A, 2.2A, 5.3A, 7.1B); fails_when=the pill is missing, the default
    /// is not 2 h, or the locked state does not land on both screens; no_claim=the haptic and the
    /// 320ms crossfade (not observable), server behavior (in-memory store).
    func testCreatorLocksAtQuorumAndHomeShowsIt() {
        let app = Self.launch("lockedInviteCreator")
        openInvite(app)
        XCTAssertEqual(any(app, "invite.caption").label, "Locked until 1 more friend overlaps")
        XCTAssertFalse(any(app, "invite.primary").exists, "no Lock pill below quorum")
        app.buttons["invite.unlock"].tap()
        XCTAssertTrue(app.buttons["availability.done"].waitForExistence(timeout: 5))
        let sat = markCell(app, day: 5, "afternoon")
        sat.tap()
        waitForLabel(sat, "Saturday afternoon, 8 of 10 free, best, you're free here")
        app.buttons["availability.done"].tap()
        waitForLabel(any(app, "invite.caption"), "Enough friends overlap")
        let lockPill = app.buttons["invite.primary"]
        XCTAssertTrue(lockPill.waitForExistence(timeout: 5))
        XCTAssertEqual(lockPill.label, "Lock Sat afternoon")
        attach(app, "invite-quorum-creator")

        lockPill.tap()
        XCTAssertTrue(any(app, "lockSheet").waitForExistence(timeout: 5))
        XCTAssertEqual(any(app, "lock.title").label, "Lock Sat, Nov 14?")
        XCTAssertTrue(app.buttons["2 h"].isSelected, "default is 2 h")
        XCTAssertEqual(any(app, "lock.window").label, "12:00–2:00 PM")
        XCTAssertTrue(any(app, "lock.attendees").label.contains("8 of 10 are in"))
        attach(app, "lock-sheet")
        app.buttons["lock.confirm"].tap()

        XCTAssertTrue(any(app, "invite.badge.locked").waitForExistence(timeout: 5))
        XCTAssertEqual(app.navigationBars.firstMatch.identifier, "Invite")
        XCTAssertEqual(any(app, "invite.lockedTime").label, "12:00–2:00 PM")
        XCTAssertEqual(any(app, "invite.attendance").label, "You're in")
        XCTAssertEqual(any(app, "invite.progress").label, "8 of 10 are in")
        XCTAssertFalse(app.buttons["invite.unlock"].exists, "the unlock link is hidden once locked")
        XCTAssertTrue(any(app, "invite.card").label.hasPrefix("Brunch, locked, Sat, Nov 14, 12:00–2:00 PM"), any(app, "invite.card").label)
        attach(app, "invite-locked")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        let cell = app.descendants(matching: .any)["heatmap.w0.d5.afternoon"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(cell.label.contains("locked"), cell.label)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Sam, in")).firstMatch.exists)
        XCTAssertTrue(app.buttons["home.share"].isEnabled)
        attach(app, "home-locked")
    }

    /// protects=durations longer than the common span are disabled and "All · 1 h 20" offers the
    /// exact span (D22); fails_when=an overlong segment is enabled or All is missing; no_claim=the
    /// Realtime re-evaluation note (LockSheetModelTests).
    func testLockSheetDisablesOverlongDurationsAndOffersAll() {
        let app = Self.launch("shortOverlap")
        openInvite(app)
        let lockPill = app.buttons["invite.primary"]
        XCTAssertTrue(lockPill.waitForExistence(timeout: 5))
        lockPill.tap()
        XCTAssertTrue(any(app, "lockSheet").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["1 h"].isEnabled)
        XCTAssertFalse(app.buttons["1 h 30"].isEnabled)
        XCTAssertFalse(app.buttons["2 h"].isEnabled)
        XCTAssertFalse(app.buttons["3 h"].isEnabled)
        XCTAssertTrue(app.buttons["All · 1 h 20"].isEnabled)
        XCTAssertTrue(app.buttons["1 h"].isSelected)
        XCTAssertEqual(any(app, "lock.window").label, "12:00–1:00 PM")
        app.buttons["All · 1 h 20"].tap()
        waitForLabel(any(app, "lock.window"), "12:00–1:20 PM")
        attach(app, "lock-sheet-short-span")
    }

    // MARK: Locked states, creator alone, Dynamic Type

    /// protects=the three locked attendance lines read from the proposal row (design 2.1A, delta O1)
    /// and the creator alone sees Invite friends with "1 of 8 joined" (1.1A); fails_when=a line is
    /// swapped or the creator alone reads "Locked until"; no_claim=copy beyond these states.
    func testLockedStatesAndCreatorAlone() {
        let rows: [(String, String, String)] = [
            ("lockedPlan", "You're in", "8 of 10 are in"),
            ("lockedWithoutYou", "Locked without you. You weren't free then.", "8 of 10 are in"),
            ("lockedLateJoiner", "Locked before you joined.", "8 of 11 are in"),
        ]
        for (fixture, line, progress) in rows {
            let app = Self.launch(fixture)
            openInvite(app)
            XCTAssertEqual(any(app, "invite.attendance").label, line, fixture)
            XCTAssertEqual(any(app, "invite.progress").label, progress, fixture)
            XCTAssertTrue(any(app, "invite.badge.locked").exists, fixture)
            attach(app, "invite-\(fixture)")
            app.terminate()
        }
        let alone = Self.launch("creatorAlone")
        openInvite(alone)
        XCTAssertEqual(any(alone, "invite.caption").label, "No one has joined yet")
        XCTAssertEqual(any(alone, "invite.progress").label, "1 of 8 joined")
        XCTAssertEqual(any(alone, "invite.primary").label, "Invite friends")
        XCTAssertEqual(alone.buttons["invite.unlock"].label, "Mark your availability")
        attach(alone, "invite-creator-alone")
    }

    /// protects=at AX5 the invite still renders the card with its text and every line is reachable by
    /// scrolling (issue AC4 of #5's original text, design 6.2A); fails_when=the card is missing or
    /// the progress line can't be reached; no_claim=truncation inside the card (screenshot).
    func testInviteAtAX5Scrolls() {
        let app = Self.launch("lockedInvite", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons["heatmap.openInvite"].tap()
        XCTAssertTrue(any(app, "invite.card").waitForExistence(timeout: 5))
        attach(app, "invite-AX5")
        let progress = any(app, "invite.progress")
        var swipes = 0
        while !progress.isHittable && swipes < 4 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(progress.isHittable, "progress line unreachable at AX5")
        attach(app, "invite-AX5-scrolled")
    }

    // MARK: Deep link (D3)

    /// protects=`friendcal://proposal/<id>` opens that invite on the Invites tab and a bad link shows
    /// the toast (D3, design 1.7A, 2.2A); fails_when=routing lands elsewhere or junk opens a screen;
    /// no_claim=cold-launch routing and iMessage tappability (DT11, device).
    func testDeepLinkOpensTheInviteAndJunkToasts() {
        let app = Self.launch("lockedInvite", extra: ["-FriendCalToastSeconds", "6"])
        XCUIDevice.shared.system.open(URL(string: "friendcal://proposal/00000000-0000-0000-0000-000000000900")!)
        XCTAssertTrue(any(app, "invite.card").waitForExistence(timeout: 10))
        XCTAssertEqual(any(app, "invite.caption").label, "Locked until 1 more friend overlaps")
        XCTAssertTrue(app.tabBars.buttons["Invites"].isSelected)
        attach(app, "deep-link-invite")
        XCUIDevice.shared.system.open(URL(string: "friendcal://nope/not-a-plan")!)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == 'toast' AND label == %@", "That link isn't a FriendCal invite")).firstMatch.waitForExistence(timeout: 5))
    }
}
