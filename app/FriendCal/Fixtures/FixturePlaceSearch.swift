import Foundation
import FriendCalCore

/// Deterministic place and city search for previews, UI tests and the fixture store (#12). Austin
/// results filtered by case-insensitive contains, plus one result beyond 25 km so the client guard
/// has something to reject. No network, no MapKit. #14 wires the launch arguments.
@MainActor
final class FixturePlaceSearch: PlaceSearching {
    private struct Entry { let title: String; let subtitle: String; let latitude: Double; let longitude: Double }

    private let entries: [Entry] = [
        Entry(title: "Cafe Lola", subtitle: "2108 E Cesar Chavez St, Austin", latitude: 30.2569, longitude: -97.7167),
        Entry(title: "Juniper Table", subtitle: "1100 S Lamar Blvd, Austin", latitude: 30.2531, longitude: -97.7650),
        Entry(title: "Bluebonnet Diner", subtitle: "1209 Barton Springs Rd, Austin", latitude: 30.2640, longitude: -97.7600),
        Entry(title: "Eastside Taqueria", subtitle: "1501 E 7th St, Austin", latitude: 30.2650, longitude: -97.7270),
        Entry(title: "Barton Springs Pool", subtitle: "2131 William Barton Dr, Austin", latitude: 30.2639, longitude: -97.7710),
        // About 40 km north of the pinned Austin center: outside the 25 km radius.
        Entry(title: "Georgetown Square Cafe", subtitle: "Georgetown, TX", latitude: 30.6333, longitude: -97.6770),
    ]
    private let cityList: [SearchArea] = [
        SearchArea(name: "Austin, TX", latitude: 30.2672, longitude: -97.7431),
        SearchArea(name: "Dallas, TX", latitude: 32.7767, longitude: -96.7970),
        SearchArea(name: "Houston, TX", latitude: 29.7604, longitude: -95.3698),
    ]

    /// The next stream or `resolve` throws this once, then clears it.
    var failNext: PlaceSearchError?

    private func takeFailure() -> PlaceSearchError? {
        defer { failNext = nil }
        return failNext
    }

    func suggestions(for query: String, in area: SearchArea) -> AsyncThrowingStream<[PlaceSuggestion], Error> {
        let failure = takeFailure()
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return AsyncThrowingStream { continuation in
            if let failure { continuation.finish(throwing: failure); return }
            guard needle.count >= 2 else { continuation.yield([]); continuation.finish(); return }
            let rows = entries.filter { ($0.title + " " + $0.subtitle).lowercased().contains(needle) }
                .map { PlaceSuggestion(id: $0.title, title: $0.title, subtitle: $0.subtitle) }
            if rows.isEmpty { continuation.finish(throwing: PlaceSearchError.noResult); return }
            continuation.yield(rows)
            continuation.finish()
        }
    }

    func resolve(_ suggestion: PlaceSuggestion, in area: SearchArea) async throws -> NewPlace {
        if let failure = takeFailure() { throw failure }
        guard let entry = entries.first(where: { $0.title == suggestion.id }) else { throw PlaceSearchError.noResult }
        // The same guard MapKitPlaceSearch applies: the 25 km radius is decided in Core, with no tolerance.
        guard area.contains(latitude: entry.latitude, longitude: entry.longitude) else { throw PlaceSearchError.outsideArea }
        return NewPlace(name: entry.title, address: entry.subtitle, latitude: entry.latitude, longitude: entry.longitude, mapRef: "fixture:\(entry.title)")
    }

    func cities(for query: String) -> AsyncThrowingStream<[PlaceSuggestion], Error> {
        let failure = takeFailure()
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return AsyncThrowingStream { continuation in
            if let failure { continuation.finish(throwing: failure); return }
            guard needle.count >= 2 else { continuation.yield([]); continuation.finish(); return }
            let rows = cityList.filter { $0.name.lowercased().contains(needle) }.map { PlaceSuggestion(id: $0.name, title: $0.name, subtitle: "") }
            if rows.isEmpty { continuation.finish(throwing: PlaceSearchError.noResult); return }
            continuation.yield(rows)
            continuation.finish()
        }
    }

    func resolveCity(_ suggestion: PlaceSuggestion) async throws -> SearchArea {
        if let failure = takeFailure() { throw failure }
        guard let city = cityList.first(where: { $0.name == suggestion.id }) else { throw PlaceSearchError.noResult }
        return city
    }
}
