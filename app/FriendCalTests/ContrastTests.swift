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

    /// protects=the destructive label on Me and on the deletion screen meets AA on both canvases,
    /// and records WHY a second red token exists; fails_when=`errorText` lightens, or someone points
    /// a destructive label at `error` again; no_claim=non-text uses of `error` as a fill or icon,
    /// which are held to the 3:1 bar below.
    ///
    /// "Delete account" is the only irreversible action in the app. The design review quoted 4.62:1
    /// for it, which does not reproduce: re-deriving `error` on `background` through the same
    /// formula this file uses gives 3.79:1 -- below AA -- and it is still only 4.01:1 on `surface`,
    /// so the shortfall was not a canvas mix-up. Hence `errorText`.
    func testDestructiveLabelMeetsAA() {
        XCTAssertGreaterThanOrEqual(Self.ratio(C.errorText, C.background), 4.5, "Delete account on canvas")
        XCTAssertGreaterThanOrEqual(Self.ratio(C.errorText, C.surface), 4.5, "Delete account on a card")

        // The regression this pair of tokens exists to prevent. If `error` ever passes, the palette
        // changed and the two tokens should be reconsidered -- but silently reverting to `error` for
        // a label must fail here first.
        XCTAssertLessThan(Self.ratio(C.error, C.background), 4.5,
                          "`error` is a fill token; if it now passes as text, revisit DesignTokens")
        XCTAssertGreaterThanOrEqual(Self.ratio(C.error, C.background), 3.0,
                                    "`error` as a non-text fill still meets 1.4.11")
    }

    /// protects=the chevron on Me's commitments row meets the 3:1 non-text bar (WCAG 1.4.11), which
    /// is why it is `accentHover` and not `accent`; fails_when=either teal token lightens or the
    /// chevron is pointed back at `accent`; no_claim=text contrast, covered above.
    func testNonTextAffordancesMeet3to1() {
        XCTAssertGreaterThanOrEqual(Self.ratio(C.accentHover, C.surface), 3.0, "commitments chevron on a card")
        XCTAssertGreaterThanOrEqual(Self.ratio(C.accentHover, C.background), 3.0, "chevron on canvas")
    }

    /// `top` at `alpha` composited over `base` in sRGB space, as a SwiftUI opacity overlay draws it.
    private static func blend(_ top: Color, over base: Color, alpha: Double) -> Color {
        let t = top.resolve(in: EnvironmentValues()), b = base.resolve(in: EnvironmentValues())
        func mix(_ a: Float, _ c: Float) -> Double { Double(a) * alpha + Double(c) * (1 - alpha) }
        return Color(.sRGB, red: mix(t.red, b.red), green: mix(t.green, b.green), blue: mix(t.blue, b.blue), opacity: 1)
    }

    /// protects=the invite card's text region (design 4.1A as corrected by delta O4): `onPrimary` over
    /// the flat 60% `text` scrim blended onto pure white, the palest art imaginable, meets 4.5:1; the
    /// white check glyph on the `success` badge meets the 3:1 non-text bar; fails_when=the scrim
    /// opacity drops, `text` lightens, or `success` lightens; no_claim=real artwork luminance beyond
    /// the white worst case, and the hero's 34pt size (large text would allow 3:1; 4.5:1 is held anyway).
    func testInviteCardScrimAndBadgeMeetAA() {
        let scrim = Self.blend(C.text, over: .white, alpha: 0.6)
        XCTAssertGreaterThanOrEqual(Self.ratio(C.onPrimary, scrim), 4.5, "hero / caption on the scrim over white art")
        XCTAssertGreaterThanOrEqual(Self.ratio(C.onPrimary, C.success), 3.0, "check glyph on the success badge")
        XCTAssertGreaterThanOrEqual(Self.ratio(C.text, C.surface2), 4.5, "DEMO badge and past-cell text on surface2")
    }

    /// protects=the places UI's two pairs on `surface2` (design PL-10): passed-row meta and the
    /// departed glyph in `textMuted`, and the outlined pill's pressed label in `accentHover`;
    /// fails_when=either token or `surface2` drifts under 4.5:1; no_claim=the glyph itself, which is
    /// non-text and held at 3:1 only.
    func testPlacesPairsOnSurface2MeetAA() {
        XCTAssertGreaterThanOrEqual(Self.ratio(C.textMuted, C.surface2), 4.5, "passed row meta on surface2")
        XCTAssertGreaterThanOrEqual(Self.ratio(C.accentHover, C.surface2), 4.5, "outlined pill pressed on surface2")
        XCTAssertGreaterThanOrEqual(Self.ratio(C.errorText, C.surface2), 4.5, "error text on surface2")
    }
}
