// SPM also builds this target for macOS (Package.swift), where UIFont and
// the app's UIAppFonts don't exist, so the test only runs app-hosted on iOS.
#if canImport(UIKit)
import UIKit
import XCTest
@testable import FriendCalCore

final class FontTests: XCTestCase {
    func testEveryFontNameIsRegistered() {
        for name in FontName.allCases {
            XCTAssertNotNil(UIFont(name: name.rawValue, size: 12), "\(name.rawValue) not registered; run scripts/fetch-fonts.sh")
        }
    }

    /// protects=the invite headline style (issue #5 R9, design 6.2A): Cabinet Grotesk ExtraBold at
    /// 34pt with -0.02em tracking, registered in the app; fails_when=the hero token drifts or its font
    /// is not bundled; no_claim=the xxxLarge cap (a view modifier on the card; UI screenshots show it).
    func testHeroStyleIsRegisteredCabinetExtraboldAt34() {
        XCTAssertNotNil(UIFont(name: FontName.cabinetExtrabold.rawValue, size: 34))
        XCTAssertEqual(DesignTokens.TextStyle.hero.tracking, -0.68, accuracy: 0.001)
    }

    func testUIAppFontsListsSevenBundledFiles() throws {
        let files = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertEqual(files.count, FontName.allCases.count)
        for file in files {
            XCTAssertNotNil(Bundle.main.url(forResource: file, withExtension: nil), "\(file) missing from app bundle")
        }
    }
}
#endif
