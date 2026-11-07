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
