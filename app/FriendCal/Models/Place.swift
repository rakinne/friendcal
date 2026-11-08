import Foundation

/// The host's city, the anchor for place search (#10 R1). Persisted as proposals.area_name,
/// area_lat and area_lon, which are all set or all null.
///
/// The SQL check is the authority: `char_length(btrim(area_name)) between 1 and 120`, latitude in
/// -90...90, longitude in -180...180. `isValid` mirrors it exactly, which means two details that are
/// easy to get wrong: `btrim` trims SPACES only, not tabs or newlines, and `char_length` counts code
/// points, so the name is measured in Unicode scalars and never with `String.count` (grapheme
/// clusters).
public struct SearchArea: Codable, Equatable, Sendable {
    /// R1: results must lie within 25 km of the city center. The one fixed radius.
    public static let radiusMeters: Double = 25_000
    public static let maxNameScalars = 120

    public var name: String          // "Austin, TX"; 1 to 120 Unicode scalars after trimming
    public var latitude: Double
    public var longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance to a point, in meters (haversine).
    public func distanceMeters(toLatitude lat: Double, longitude lon: Double) -> Double {
        let earthRadius = 6_371_000.0
        let p1 = latitude * .pi / 180, p2 = lat * .pi / 180
        let dp = (lat - latitude) * .pi / 180, dl = (lon - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// True when the point is within `radiusMeters` of the center. The one place R1's boundary is
    /// decided; there is no tolerance.
    public func contains(latitude lat: Double, longitude lon: Double) -> Bool {
        distanceMeters(toLatitude: lat, longitude: lon) <= Self.radiusMeters
    }

    /// The SQL check `proposals_area_all_or_none`, for a city that is set.
    public var isValid: Bool {
        let scalars = PlaceText.trim(name).unicodeScalars.count
        return (1...Self.maxNameScalars).contains(scalars)
            && latitude.isFinite && longitude.isFinite
            && (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }
}

/// Text rules shared by the city and the place fields, matching the SQL's `btrim`.
public enum PlaceText {
    /// Postgres `btrim(x)` removes leading and trailing SPACES (U+0020) only, one code point at a time.
    /// It walks the Unicode scalars, not Characters: a space followed by a combining mark is ONE
    /// Character in Swift, and trimming by Character would leave the space that `btrim` removes.
    public static func trim(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while scalars.first == " " { scalars = scalars.dropFirst() }
        while scalars.last == " " { scalars = scalars.dropLast() }
        return String(scalars)
    }

    /// `nullif(btrim(x), '')`.
    public static func trimmedOrNil(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = trim(text)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct Place: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var proposalID: UUID
    public var suggestedBy: UUID
    public var name: String
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    /// MKMapItem.Identifier raw value; nil when MapKit gave none.
    public var mapRef: String?
    public var vetoedAt: Date?
    public var createdAt: Date
    public var isVetoed: Bool { vetoedAt != nil }

    public init(id: UUID = UUID(), proposalID: UUID, suggestedBy: UUID, name: String, address: String? = nil,
                latitude: Double, longitude: Double, mapRef: String? = nil, vetoedAt: Date? = nil, createdAt: Date) {
        self.id = id
        self.proposalID = proposalID
        self.suggestedBy = suggestedBy
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.mapRef = mapRef
        self.vetoedAt = vetoedAt
        self.createdAt = createdAt
    }
}

public struct PlaceVote: Codable, Equatable, Sendable {
    public var proposalID: UUID
    public var voterID: UUID
    public var placeID: UUID
    public var createdAt: Date

    public init(proposalID: UUID, voterID: UUID, placeID: UUID, createdAt: Date) {
        self.proposalID = proposalID
        self.voterID = voterID
        self.placeID = placeID
        self.createdAt = createdAt
    }
}

/// A place a friend wants to suggest, before the server gives it an id and a timestamp.
public struct NewPlace: Equatable, Sendable {
    public var name: String
    public var address: String?
    public var latitude: Double
    public var longitude: Double
    public var mapRef: String?

    public init(name: String, address: String? = nil, latitude: Double, longitude: Double, mapRef: String? = nil) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.mapRef = mapRef
    }
}
