import SwiftUI
import XCTest
@testable import FriendCalCore

/// WCAG 2.x contrast for every text/fill pair Home draws (D25, DT5). Reads the real tokens, so a
/// palette edit re-runs the check.
///
/// Not asserted, on purpose:
/// - Wordmark coral on cream (2.95:1): a logotype, exempt under WCAG 1.4.3.
/// - Disabled Share (muted on peach-light): inactive controls are exempt.
final class ContrastTests: XCTestCase {
    private typealias C = DesignTokens.Colors

    /// WCAG relative luminance from the resolved linear sRGB components.
    private static func luminance(_ color: Color) -> Double {
        let r = color.resolve(in: EnvironmentValues())
        return 0.2126 * Double(r.linearRed) + 0.7152 * Double(r.linearGreen) + 0.0722 * Double(r.linearBlue)
    }

    static func ratio(_ a: Color, _ b: Color) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// protects=the ratio math the pair test relies on; fails_when=luminance uses gamma-encoded
    /// components or the formula drifts (black/white must be 21:1, a color with itself 1:1);
    /// no_claim=any token pair.
    func testRatioMathAnchors() {
        XCTAssertEqual(Self.ratio(.black, .white), 21, accuracy: 0.01)
        XCTAssertEqual(Self.ratio(C.primary, C.primary), 1, accuracy: 0.0001)
        XCTAssertEqual(Self.ratio(C.text, C.primary), 5.55, accuracy: 0.01) // D25's quoted value
    }

    /// protects=every Home text/fill pair meets AA: 4.5:1 for body text, 3:1 for Poke's 17pt
    /// semibold label (D25's large-text exception); fails_when=a token change drops any listed
    /// pair below its bar; no_claim=pairs not listed (new components must add theirs) and
    /// whether 17pt semibold truly counts as large text (eng run-2 Section 2 note 5, left to
    /// design review).
    func testHomeTextPairsMeetAA() {
        let body: [(String, Color, Color)] = [
            ("text on canvas", C.text, C.background),
            ("text on card / chip / pill", C.text, C.surface),
            ("numeral on peach-light", C.text, C.peachLight),
            ("numeral on peach", C.text, C.peach),
            ("numeral on orange", C.text, C.heatOrange),
            ("numeral on primary", C.text, C.primary),
            ("muted on canvas", C.textMuted, C.background),
            ("muted on card", C.textMuted, C.surface),
            ("teal text (online-ish) on canvas", C.accentHover, C.background),
            ("teal text (LIVE) on card", C.accentHover, C.surface),
            ("Share / Invite / Request label", C.onPrimary, C.accentHover),
            ("toast", C.surface, C.text),
        ] + DesignTokens.FacePalette.colors.enumerated().map { ("initials on face \($0.offset)", C.text, $0.element) }

        for (name, fg, bg) in body {
            XCTAssertGreaterThanOrEqual(Self.ratio(fg, bg), 4.5, name)
        }
        XCTAssertGreaterThanOrEqual(Self.ratio(C.onPrimary, C.primary), 3.0, "Poke label (17pt semibold)")
    }
}
