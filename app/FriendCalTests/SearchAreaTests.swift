import XCTest
@testable import FriendCalCore

/// The 25 km boundary (R1) and the city-name rules, which mirror the SQL check
/// `proposals_area_all_or_none` including its `btrim` and `char_length` semantics.
final class SearchAreaTests: XCTestCase {
    private let austin = SearchArea(name: "Austin, TX", latitude: 30.2672, longitude: -97.7431)
    /// One degree of latitude on a sphere of radius 6,371,000 m, in meters.
    private let metersPerDegree = 2 * Double.pi * 6_371_000 / 360

    /// protects=a point 24 km away is contained and 26 km is not, so the one place R1's boundary is
    /// decided is right and in meters, not degrees; fails_when=the radius is compared in degrees, off
    /// by a unit, or given a tolerance; no_claim=what MapKit itself returns near the edge (the device
    /// check, #12 criterion 10).
    func testTheBoundaryIsTwentyFiveKilometers() {
        XCTAssertEqual(SearchArea.radiusMeters, 25_000)
        XCTAssertTrue(austin.contains(latitude: austin.latitude + 24_000 / metersPerDegree, longitude: austin.longitude))
        XCTAssertFalse(austin.contains(latitude: austin.latitude + 26_000 / metersPerDegree, longitude: austin.longitude))
        XCTAssertTrue(austin.contains(latitude: austin.latitude, longitude: austin.longitude))
    }

    /// protects=haversine distance is right to about a kilometer on a known pair and symmetric;
    /// fails_when=the formula drops the latitude scaling of longitude or uses the wrong radius;
    /// no_claim=sub-meter accuracy.
    func testDistanceOnAKnownPair() {
        let dallas = SearchArea(name: "Dallas, TX", latitude: 32.7767, longitude: -96.7970)
        let d = austin.distanceMeters(toLatitude: dallas.latitude, longitude: dallas.longitude)
        XCTAssertEqual(d, 293_095, accuracy: 1_000)
        XCTAssertEqual(dallas.distanceMeters(toLatitude: austin.latitude, longitude: austin.longitude), d, accuracy: 0.001)
        XCTAssertEqual(austin.distanceMeters(toLatitude: austin.latitude, longitude: austin.longitude), 0, accuracy: 0.001)
    }

    /// protects=the name is measured after trimming SPACES, in code points, as the SQL check does:
    /// a single space is refused, 120 characters padded with spaces are accepted, 121 are refused,
    /// 120 multi-byte characters are accepted, and 61 characters that are 122 code points are
    /// refused although `String.count` says 61; fails_when=Swift counts graphemes, trims newlines the
    /// SQL does not, or skips the trim; no_claim=every Unicode normalization form.
    func testNameBoundsMatchTheSQLCheck() {
        func valid(_ name: String, lat: Double = 30, lon: Double = -97) -> Bool {
            SearchArea(name: name, latitude: lat, longitude: lon).isValid
        }
        XCTAssertFalse(valid(" "))
        XCTAssertFalse(valid(""))
        XCTAssertTrue(valid("   " + String(repeating: "a", count: 120) + "   "))
        XCTAssertFalse(valid(String(repeating: "a", count: 121)))
        XCTAssertTrue(valid(String(repeating: "é", count: 120)))
        let combining = String(repeating: "e\u{0301}", count: 61)
        XCTAssertEqual(combining.count, 61)
        XCTAssertEqual(combining.unicodeScalars.count, 122)
        XCTAssertFalse(valid(combining), "122 code points exceed 120 even though there are 61 characters")
        XCTAssertTrue(valid("\t"), "btrim removes spaces only, so a lone tab is one code point")
    }

    /// protects=out-of-range and non-finite coordinates are invalid; fails_when=latitude 91, longitude
    /// 181 or NaN is accepted; no_claim=whether the place is real.
    func testCoordinateBounds() {
        func valid(_ lat: Double, _ lon: Double) -> Bool { SearchArea(name: "X", latitude: lat, longitude: lon).isValid }
        XCTAssertTrue(valid(90, 180))
        XCTAssertTrue(valid(-90, -180))
        XCTAssertFalse(valid(90.5, 0))
        XCTAssertFalse(valid(0, 180.5))
        XCTAssertFalse(valid(.nan, 0))
        XCTAssertFalse(valid(0, .infinity))
    }
}
