import XCTest
@testable import FriendCalCore

/// The host's remembered city (design 3.1A). Each test uses its own UserDefaults suite so nothing
/// leaks between tests or into the app's real defaults.
final class LastUsedCityTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let austin = SearchArea(name: "Austin, TX", latitude: 30.2672, longitude: -97.7431)

    override func setUp() {
        suite = "LastUsedCityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// protects=a saved city comes back unchanged and nothing saved is nil, so New plan prefills a
    /// returning host and starts empty for a new one; fails_when=the codec drops a field or `load`
    /// invents a default city; no_claim=cross-device sync (the value is per device).
    func testSaveThenLoadRoundTripsAndEmptyIsNil() {
        let store = LastUsedCity(defaults: defaults)
        XCTAssertNil(store.load())
        store.save(austin)
        XCTAssertEqual(store.load(), austin)
    }

    /// protects=a newer save replaces the older one (a city is replaced, never accumulated);
    /// fails_when=save appends or keeps the first; no_claim=history of cities.
    func testSavingAgainReplaces() {
        let store = LastUsedCity(defaults: defaults)
        store.save(austin)
        let dallas = SearchArea(name: "Dallas, TX", latitude: 32.7767, longitude: -96.7970)
        store.save(dallas)
        XCTAssertEqual(store.load(), dallas)
    }

    /// protects=an invalid city is never stored and a stale or corrupt stored value reads as nil, so
    /// Create cannot be handed a city the SQL check would refuse; fails_when=`save` skips `isValid` or
    /// `load` trusts the stored text; no_claim=the exact bounds (SearchAreaTests owns those).
    func testInvalidAndCorruptValuesAreIgnored() {
        let store = LastUsedCity(defaults: defaults)
        store.save(SearchArea(name: "   ", latitude: 30, longitude: -97))
        store.save(SearchArea(name: "Nowhere", latitude: 123, longitude: -97))
        XCTAssertNil(store.load(), "an invalid city is not stored")

        for corrupt in ["not a city", "Austin, TX|30.2", "Austin, TX|north|-97.7", "none", ""] {
            defaults.set(corrupt, forKey: LastUsedCity.key)
            XCTAssertNil(store.load(), "\"\(corrupt)\" is nil")
        }
        defaults.set("  |30|-97", forKey: LastUsedCity.key)
        XCTAssertNil(store.load(), "a stored invalid city is nil")
    }

    /// protects=the exact text a UI test passes as `-FriendCalLastCity` loads, and a name that itself
    /// contains the separator still parses (the last two fields are the coordinates); fails_when=the
    /// stored shape changes without the UI tests being updated, or the parse splits on the first
    /// separator; no_claim=anything about the UI.
    func testALaunchArgumentShapedValueLoads() {
        defaults.set("Austin, TX|30.2672|-97.7431", forKey: LastUsedCity.key)
        XCTAssertEqual(LastUsedCity(defaults: defaults).load(), austin)

        let odd = SearchArea(name: "Left | Right", latitude: 1.5, longitude: -2.5)
        LastUsedCity(defaults: defaults).save(odd)
        XCTAssertEqual(LastUsedCity(defaults: defaults).load(), odd)
    }

    /// Value: protects=clear() forgets the saved city so the next account on the device starts with none; fails_when=clear stops removing the key or sign-out stops calling it; why_new=no test covers removal; seam=none; no_claim=that MeView calls clear (UI path)
    func testClearForgetsTheSavedCity() {
        let store = LastUsedCity(defaults: defaults)
        store.save(austin)
        XCTAssertNotNil(store.load())
        store.clear()
        XCTAssertNil(store.load())
    }
}
