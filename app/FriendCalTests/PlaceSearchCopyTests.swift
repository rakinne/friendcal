// PlaceSearchCopy and PlaceSearchProvider live in the app target; SPM builds this folder against
// FriendCalCore only, so the file runs app-hosted under Xcode (same as ProposalSessionTests).
#if canImport(FriendCal)
import XCTest
@testable import FriendCal
@testable import FriendCalCore

/// Search failure sentences and the launch-argument provider (#14).
final class PlaceSearchCopyTests: XCTestCase {
    /// Value: protects=each PlaceSearchError maps to the design-approved sentence, with and without an area name; fails_when=a case is reworded, swapped or the km radius drifts from SearchArea; why_new=UI tests only reach offline and noResult; seam=none; no_claim=how the sentence is laid out on screen
    func testEveryErrorMapsToItsApprovedSentence() {
        XCTAssertEqual(PlaceSearchCopy.message(for: .throttled), "Searching too fast. Wait a moment and try again.")
        XCTAssertEqual(PlaceSearchCopy.message(for: .offline), "No connection. Check your internet and try again.")
        XCTAssertEqual(PlaceSearchCopy.message(for: .noResult), "No city found. Try another name.")
        XCTAssertEqual(PlaceSearchCopy.message(for: .noResult, areaName: "Austin, TX"), "No places found near Austin, TX. Try another name.")
        XCTAssertEqual(PlaceSearchCopy.message(for: .outsideArea), "That's outside the city. Try a place within 25 km.")
        XCTAssertEqual(PlaceSearchCopy.message(for: .outsideArea, areaName: "Austin, TX"), "That's outside Austin, TX. Try a place within 25 km.")
    }

    /// Value: protects=only the exact launch value "fixture" selects the offline fixture search, anything else keeps MapKit; fails_when=the default flips to fixture or the key is renamed; why_new=no test reads the provider selection; seam=none; no_claim=MapKit behavior (no network in unit tests)
    @MainActor
    func testProviderSelectionFollowsTheLaunchArgument() {
        let name = "PlaceSearchCopyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(PlaceSearchProvider.fromLaunchArguments(defaults).make() is MapKitPlaceSearch)
        defaults.set("other", forKey: "FriendCalSearch")
        XCTAssertTrue(PlaceSearchProvider.fromLaunchArguments(defaults).make() is MapKitPlaceSearch)
        defaults.set("fixture", forKey: "FriendCalSearch")
        XCTAssertTrue(PlaceSearchProvider.fromLaunchArguments(defaults).make() is FixturePlaceSearch)
    }
}
#endif
