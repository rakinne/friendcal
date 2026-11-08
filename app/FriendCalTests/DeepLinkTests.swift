import XCTest
@testable import FriendCalCore

/// `friendcal://proposal/<uuid>` (issue #5 D3).
final class DeepLinkTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000900")!

    /// protects=a shared link opens exactly the proposal it names and junk opens nothing;
    /// fails_when=the parser accepts another scheme or host, a bad id, or extra path parts, or
    /// rejects a differently-cased link; no_claim=iOS routing the URL to the app.
    func testParseTable() {
        let rows: [(String, DeepLink?)] = [
            ("friendcal://proposal/\(id.uuidString)", .proposal(id)),
            ("friendcal://proposal/\(id.uuidString.lowercased())", .proposal(id)),
            ("FRIENDCAL://PROPOSAL/\(id.uuidString)", .proposal(id)),
            ("https://proposal/\(id.uuidString)", nil),
            ("friendcal://plan/\(id.uuidString)", nil),
            ("friendcal://proposal/not-a-uuid", nil),
            ("friendcal://proposal/\(id.uuidString)/extra", nil),
            ("friendcal://proposal", nil),
            ("friendcal://proposal/", nil),
        ]
        for (text, expected) in rows {
            XCTAssertEqual(DeepLink.parse(URL(string: text)!), expected, text)
        }
    }

    /// protects=the link the app shares parses back to the same proposal and uses the one scheme
    /// constant; fails_when=url() and parse() disagree or the scheme string drifts; no_claim=none beyond protects.
    func testURLRoundTrip() {
        let link = DeepLink.proposal(id)
        XCTAssertEqual(link.url.absoluteString, "friendcal://proposal/00000000-0000-0000-0000-000000000900")
        XCTAssertEqual(DeepLink.parse(link.url), link)
        XCTAssertEqual(DeepLink.scheme, "friendcal")
    }
}

#if canImport(FriendCal)
import FriendCal

final class DeepLinkBundleTests: XCTestCase {
    /// protects=CFBundleURLTypes in the built app registers DeepLink.scheme, so the parser and
    /// project.yml cannot drift apart (eng review red flag 8); fails_when=either side renames the
    /// scheme alone; no_claim=iOS honoring the registration (manual device check, DT11).
    func testBundleRegistersTheScheme() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertEqual(schemes, [DeepLink.scheme])
    }
}
#endif

/// The title hint on a deep link (G16): parsed through URLComponents, sanitized once at the
/// boundary, and never trusted.
///
/// The hint exists because a link holder cannot read the plan until they have joined it, so the
/// invite screen would otherwise have nothing to show at the moment someone decides whether to
/// bother. It arrives from outside the app, so these tests are mostly about what gets thrown away.
final class DeepLinkTitleTests: XCTestCase {
    private let id = UUID(uuidString: "4C8E7A90-0000-0000-0000-000000000001")!

    private func parsed(_ string: String) -> DeepLink? {
        URL(string: string).flatMap(DeepLink.parse)
    }

    /// protects=a plain title surviving the round trip, percent-encoding included; fails_when=the
    /// query is hand-split instead of read through URLComponents, so an apostrophe or a space
    /// arrives still encoded; no_claim=what the screen does with it.
    func testTitleRoundTripsThroughTheURL() {
        let link = DeepLink.proposal(id, title: "Dad's 60th & brunch")
        let reparsed = DeepLink.parse(link.url)
        XCTAssertEqual(reparsed?.title, "Dad's 60th & brunch")
        XCTAssertEqual(reparsed?.proposalID, id)
        XCTAssertEqual(reparsed, link)
    }

    /// protects=a link with no title still parsing, so the hint is genuinely optional and old links
    /// keep working; fails_when=the title becomes required.
    func testLinkWithoutATitleStillParses() {
        XCTAssertEqual(parsed("friendcal://proposal/\(id.uuidString)"), .proposal(id, title: nil))
        XCTAssertNil(parsed("friendcal://proposal/\(id.uuidString)")?.title)
        // And a link built without one carries no query at all, rather than an empty `t=`.
        XCTAssertNil(URLComponents(url: DeepLink.proposal(id).url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    /// protects=an empty or whitespace-only title collapsing to nil, so "no usable title" has one
    /// representation; fails_when=an empty string reaches the UI and renders as a blank headline.
    func testEmptyTitleBecomesNil() {
        XCTAssertNil(DeepLink.sanitizedTitle(""))
        XCTAssertNil(DeepLink.sanitizedTitle("   \n\t "))
        XCTAssertNil(DeepLink.sanitizedTitle(nil))
        XCTAssertNil(parsed("friendcal://proposal/\(id.uuidString)?t=")?.title)
        XCTAssertNil(parsed("friendcal://proposal/\(id.uuidString)?t=%20%20")?.title)
    }

    /// protects=bidi overrides, zero-width characters and control characters being removed;
    /// fails_when=sanitizing only trims whitespace. A right-to-left override in a "title" reorders
    /// the text around it, so a crafted link can make the rest of the screen read as something else;
    /// zero-width characters let two different titles look identical.
    func testHostileTitlesAreStripped() {
        XCTAssertEqual(DeepLink.sanitizedTitle("Brunch\u{202E}hctnurB"), "BrunchhctnurB")
        XCTAssertEqual(DeepLink.sanitizedTitle("Bru\u{200B}nch"), "Brunch")
        XCTAssertEqual(DeepLink.sanitizedTitle("Brunch\u{FEFF}"), "Brunch")
        XCTAssertEqual(DeepLink.sanitizedTitle("Line\nbreak"), "Linebreak")
        XCTAssertEqual(DeepLink.sanitizedTitle("Tab\there"), "Tabhere")
        XCTAssertEqual(DeepLink.sanitizedTitle("\u{2066}Brunch\u{2069}"), "Brunch")
        // Ordinary non-ASCII is content, not an attack, and must survive.
        XCTAssertEqual(DeepLink.sanitizedTitle("Café brunch 🥐"), "Café brunch 🥐")
    }

    /// protects=the length cap, so a payload cannot push real content off the invite card;
    /// fails_when=the cap is removed or applied before trimming.
    func testTitleIsCapped() {
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(DeepLink.sanitizedTitle(long)?.count, DeepLink.maxTitleLength)
        // Trim happens before the cap, so padding cannot consume the budget.
        XCTAssertEqual(DeepLink.sanitizedTitle("   " + String(repeating: "b", count: 10) + "   "),
                       String(repeating: "b", count: 10))
    }

    /// protects=sanitizing happening on the way OUT too, so a link we hand someone cannot carry what
    /// we would refuse on arrival; fails_when=only `parse` sanitizes.
    func testOutboundLinksAreSanitizedToo() {
        let link = DeepLink.proposal(id, title: "Brunch\u{202E}evil").url
        XCTAssertFalse(link.absoluteString.contains("%E2%80%AE"), "the bidi override must not be in the URL we share")
        XCTAssertEqual(DeepLink.parse(link)?.title, "Brunchevil")
    }

    /// protects=a repeated query key resolving deterministically rather than by parse order;
    /// fails_when=the last one wins in some builds and the first in others.
    func testRepeatedTitleKeyTakesTheFirst() {
        XCTAssertEqual(parsed("friendcal://proposal/\(id.uuidString)?t=First&t=Second")?.title, "First")
    }

    /// protects=an unrelated query item not being mistaken for the title; fails_when=the parser takes
    /// the first query item rather than the one named `t`.
    func testOtherQueryItemsAreIgnored() {
        XCTAssertEqual(parsed("friendcal://proposal/\(id.uuidString)?utm=x&t=Brunch")?.title, "Brunch")
        XCTAssertNil(parsed("friendcal://proposal/\(id.uuidString)?utm=x")?.title)
    }

    /// protects=the title never widening what parses: a malformed link stays nil whatever its query
    /// says; fails_when=adding the query made the path checks laxer.
    func testTitleDoesNotRescueAMalformedLink() {
        XCTAssertNil(parsed("friendcal://proposal/not-a-uuid?t=Brunch"))
        XCTAssertNil(parsed("friendcal://other/\(id.uuidString)?t=Brunch"))
        XCTAssertNil(parsed("https://proposal/\(id.uuidString)?t=Brunch"))
        XCTAssertNil(parsed("friendcal://proposal/\(id.uuidString)/extra?t=Brunch"))
    }
}
