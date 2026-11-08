import Foundation

/// One autocomplete row. `id` is opaque to callers; the implementation maps it back to its own
/// completion object when the row is resolved.
public struct PlaceSuggestion: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String

    public init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

public enum PlaceSearchError: Error, Equatable, Sendable {
    case throttled, noResult, offline, outsideArea
}

/// Place and city search behind a seam that imports no MapKit, so the rules around it (the 25 km
/// guard, the duplicate rule, the error mapping) are testable in the core lane and the fixtures can
/// stand in for it. The MapKit implementation lives in the app target.
@MainActor
public protocol PlaceSearching: AnyObject {
    /// Autocomplete rows for `query` inside `area`. An empty or one-character query yields [].
    /// The stream throws `PlaceSearchError`, which is how throttled and offline reach the UI.
    func suggestions(for query: String, in area: SearchArea) -> AsyncThrowingStream<[PlaceSuggestion], Error>
    /// Resolves a row to a place. Throws `.outsideArea` when it lies beyond `area.radiusMeters`.
    func resolve(_ suggestion: PlaceSuggestion, in area: SearchArea) async throws -> NewPlace
    /// Cities for the host's picker. No area bias.
    func cities(for query: String) -> AsyncThrowingStream<[PlaceSuggestion], Error>
    func resolveCity(_ suggestion: PlaceSuggestion) async throws -> SearchArea
}
