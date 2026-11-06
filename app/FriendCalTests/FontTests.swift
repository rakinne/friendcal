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

    func testUIAppFontsListsSevenBundledFiles() throws {
        let files = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertEqual(files.count, FontName.allCases.count)
        for file in files {
            XCTAssertNotNil(Bundle.main.url(forResource: file, withExtension: nil), "\(file) missing from app bundle")
        }
    }
}
#endif
