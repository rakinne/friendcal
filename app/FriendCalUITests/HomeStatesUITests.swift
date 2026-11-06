import XCTest
import UIKit

/// D19 state matrix, appearance lock (D33) and Dynamic Type (D31). Each test attaches a
/// screenshot for /ios-design-review (no pixel baselines) and asserts the state's defining
/// element, so a wrong state fails rather than just looking wrong.
final class HomeStatesUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = .light
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
    }

    private func launch(_ fixture: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FriendCalFixture", fixture] + extra
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

    /// protects=loading draws custom skeletons, not live data (D19); fails_when=real modules
    /// (Poke, cells, wheel faces) render while loading; no_claim=skeleton shapes match the mock.
    func testLoading() {
        let app = launch("loading")
        XCTAssertTrue(app.staticTexts["Loading overlap"].waitForExistence(timeout: 10) || any(app, "heatmapCard").waitForExistence(timeout: 1))
        XCTAssertFalse(app.buttons["home.poke"].exists)
        XCTAssertFalse(any(app, "heatmap.w0.d5.afternoon").exists)
        attach(app, "state-loading")
    }

    /// protects=first run with no friends and no proposal is welcoming, not blank (D19);
    /// fails_when=the invite or "No plans brewing" prompt is missing; no_claim=stub actions.
    func testNoFriends() {
        let app = launch("noFriends")
        XCTAssertTrue(app.staticTexts["Add your first fave"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["wheel.invite"].exists)
        XCTAssertTrue(app.staticTexts["No plans brewing"].exists)
        XCTAssertFalse(app.buttons["home.share"].isEnabled)
        attach(app, "state-no-friends")
    }

    /// protects=1-3 friends render without the overflow face (D19); fails_when="+N" appears or a
    /// face is missing; no_claim=arc drawing (visual).
    func testFewFriends() {
        let app = launch("fewFriends")
        XCTAssertTrue(app.buttons["home.poke"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["wheel.more"].exists)
        for name in ["Sam", "Maya", "Leo"] {
            XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), ")).count > 0, true, name)
        }
        attach(app, "state-few-friends")
    }

    /// protects=members without a proposal see "No plans brewing" + Request times (D19);
    /// fails_when=a grid renders or the action is missing; no_claim=request flow (stub).
    func testNoProposal() {
        let app = launch("noProposal")
        XCTAssertTrue(app.staticTexts["No plans brewing"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["heatmap.requestTimes"].exists)
        XCTAssertFalse(any(app, "heatmap.w0.d5.afternoon").exists)
        attach(app, "state-no-proposal")
    }

    /// protects=zero overlap shows the grid plus "No overlap yet. Nudge your crew." (D19);
    /// fails_when=the message is missing; no_claim=Share disabled (HomeUITests owns it).
    func testZeroOverlap() {
        let app = launch("zeroOverlap")
        XCTAssertTrue(any(app, "heatmap.noOverlap").waitForExistence(timeout: 10))
        attach(app, "state-zero-overlap")
    }

    /// protects=a single-week window hides the page dots (D19); fails_when=dots render for one
    /// week; no_claim=paging (HomeUITests).
    func testSingleWeekHidesPageDots() {
        let app = launch("singleWeek")
        XCTAssertTrue(any(app, "heatmap.w0.d5.afternoon").waitForExistence(timeout: 10))
        XCTAssertFalse(any(app, "heatmap.pageIndicator").exists)
        attach(app, "state-single-week")
    }

    /// protects=data older than 5 minutes swaps LIVE for "Updated Nm ago" (D19); fails_when=LIVE
    /// shows for stale data; no_claim=the exact minute count across a minute boundary.
    func testStaleShowsUpdatedAgo() {
        let app = launch("stale")
        // The header combines its children, so it also carries this identifier; the badge itself
        // is the element whose label is only the status.
        XCTAssertTrue(any(app, "heatmapCard").waitForExistence(timeout: 10))
        let badges = app.descendants(matching: .any).matching(identifier: "heatmap.live")
        let labels = (0..<badges.count).map { badges.element(boundBy: $0).label }
        XCTAssertTrue(labels.contains { $0.hasPrefix("Updated ") && $0.hasSuffix("minutes ago") }, "\(labels)")
        XCTAssertFalse(labels.contains("Live"), "\(labels)")
        attach(app, "state-stale")
    }

    /// protects=the app stays light when the system is dark (D33), including system chrome;
    /// fails_when=the tab bar renders dark glass; no_claim=every surface (one chrome sample plus
    /// the screenshot).
    func testDarkSystemAppearanceRendersLight() throws {
        XCUIDevice.shared.appearance = .dark
        let app = launch("populated")
        XCTAssertTrue(app.buttons["home.poke"].waitForExistence(timeout: 10))
        let bar = app.tabBars.firstMatch.frame
        let shot = app.screenshot()
        attach(app, "appearance-system-dark")
        let image = try XCTUnwrap(shot.image.cgImage)
        let scale = CGFloat(image.width) / shot.image.size.width
        // Inside the floating bar, left of the first item's icon.
        let point = CGPoint(x: (bar.minX + 10) * scale, y: bar.midY * scale)
        let luma = try XCTUnwrap(Self.luminance(of: image, at: point))
        XCTAssertGreaterThan(luma, 0.6, "tab bar sample is dark (\(luma)); light mode lock not applied")
    }

    /// protects=at xxxLarge and AX3 the heatmap and wheel stay capped (D31 + amendment), the
    /// header stacks instead of truncating the group pill, and the page scrolls to every module;
    /// fails_when=a heatmap cell grows past the card, the wheel centre text overlaps a face, the
    /// pill stays beside the wordmark at AX3, or the stealth row can't be reached; no_claim=
    /// truncation inside other modules (screenshots show it).
    func testDynamicTypeLargeSizes() {
        for (size, name) in [("UICTContentSizeCategoryXXXL", "xxxLarge"), ("UICTContentSizeCategoryAccessibilityL", "AX3")] {
            let app = launch("populated", extra: ["-UIPreferredContentSizeCategoryName", size])
            let sat = any(app, "heatmap.w0.d5.afternoon")
            XCTAssertTrue(sat.waitForExistence(timeout: 10), name)
            XCTAssertTrue(any(app, "heatmapCard").frame.contains(sat.frame), name)
            let center = any(app, "wheel.center").frame
            let faces = app.descendants(matching: .any).matching(identifier: "wheel.face")
            XCTAssertEqual(faces.count, 9, name)
            for i in 0..<faces.count {
                XCTAssertFalse(center.intersects(faces.element(boundBy: i).frame), "\(name): centre overlaps \(faces.element(boundBy: i).label)")
            }
            let pill = any(app, "home.groupPill").frame
            // Inside the 20pt margin, with 1pt for sub-point layout rounding at the pill's edge.
            XCTAssertLessThanOrEqual(pill.maxX, app.windows.firstMatch.frame.maxX - 19, name)
            if name == "AX3" {
                XCTAssertGreaterThanOrEqual(pill.minY, any(app, "home.wordmark").frame.maxY, "AX3: pill not stacked under the wordmark")
            }
            attach(app, "dynamic-type-\(name)")
            let stealth = app.switches["home.stealth"]
            var swipes = 0
            while !stealth.isHittable && swipes < 4 { app.swipeUp(); swipes += 1 }
            XCTAssertTrue(stealth.isHittable, "\(name): stealth row unreachable")
            attach(app, "dynamic-type-\(name)-scrolled")
            app.terminate()
        }
    }

    private static func luminance(of image: CGImage, at p: CGPoint) -> CGFloat? {
        guard p.x >= 0, p.y >= 0, Int(p.x) < image.width, Int(p.y) < image.height,
              let crop = image.cropping(to: CGRect(x: Int(p.x), y: Int(p.y), width: 1, height: 1)) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (0.299 * CGFloat(pixel[0]) + 0.587 * CGFloat(pixel[1]) + 0.114 * CGFloat(pixel[2])) / 255
    }
}
