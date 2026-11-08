import Foundation
import MapKit
import FriendCalCore

/// Place and city search over MapKit (#12). App target only: MapKit is not compiled into FriendCalCore,
/// which also builds for macOS under `swift test`. Everything decidable without MapKit stays in Core.
///
/// - Place suggestions use `MKLocalSearchCompleter` with `resultTypes = .pointOfInterest`, `region` a
///   50,000 m square around the city, and `regionPriority = .required`.
/// - City suggestions use `resultTypes = .address` and an `MKAddressFilter` that includes localities.
/// - A query is debounced 250 ms, needs two characters, and a new query cancels the previous one (the
///   consumer cancels the stream; `onTermination` tears the completer down). Apple's guidance is serial
///   requests, one per user action.
/// - **Client-side guard.** `resolve` rejects any item for which `SearchArea.contains` is false, with
///   `.outsideArea`. That decision lives in Core and is tested there. There is no tolerance: the 25 km
///   radius is the authoritative boundary for R1. The request region is a 50 km square, whose corners
///   lie beyond 25 km, so the guard also trims those, and it protects R1 even if the region priority is
///   looser than documented. What `.required` does at the edge is unverified until the device check
///   (#12 criterion 10).
/// - Only APIs available on iOS 18.0. The deployment target enforces that at build time.
@MainActor
final class MapKitPlaceSearch: PlaceSearching {
    private static let debounce: Duration = .milliseconds(250)
    private static let squareMeters: CLLocationDistance = 50_000

    /// Completions by suggestion id, so a tapped row can be resolved. Rebuilt on every result set.
    private var completions: [String: MKLocalSearchCompletion] = [:]
    private var citySuggestions: [String: MKLocalSearchCompletion] = [:]

    // MARK: PlaceSearching

    func suggestions(for query: String, in area: SearchArea) -> AsyncThrowingStream<[PlaceSuggestion], Error> {
        stream(query: query, configure: { completer in
            completer.resultTypes = .pointOfInterest
            completer.region = Self.region(around: area)
            completer.regionPriority = .required
        }, remember: { [weak self] rows in self?.completions = rows })
    }

    func resolve(_ suggestion: PlaceSuggestion, in area: SearchArea) async throws -> NewPlace {
        guard let completion = completions[suggestion.id] else { throw PlaceSearchError.noResult }
        let request = MKLocalSearch.Request(completion: completion)
        request.region = Self.region(around: area)
        request.regionPriority = .required
        let item = try await Self.first(of: request)
        let coordinate = item.placemark.coordinate
        guard area.contains(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            throw PlaceSearchError.outsideArea
        }
        return NewPlace(name: item.name ?? completion.title,
                        address: Self.address(of: item) ?? Self.nonEmpty(completion.subtitle),
                        latitude: coordinate.latitude, longitude: coordinate.longitude,
                        mapRef: item.identifier?.rawValue)
    }

    func cities(for query: String) -> AsyncThrowingStream<[PlaceSuggestion], Error> {
        stream(query: query, configure: { completer in
            completer.resultTypes = .address
            completer.addressFilter = MKAddressFilter(including: [.locality])
        }, remember: { [weak self] rows in self?.citySuggestions = rows })
    }

    func resolveCity(_ suggestion: PlaceSuggestion) async throws -> SearchArea {
        guard let completion = citySuggestions[suggestion.id] else { throw PlaceSearchError.noResult }
        let item = try await Self.first(of: MKLocalSearch.Request(completion: completion))
        let coordinate = item.placemark.coordinate
        let name = [item.placemark.locality, item.placemark.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        return SearchArea(name: name.isEmpty ? (item.name ?? completion.title) : name,
                          latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    // MARK: Private

    private static func region(around area: SearchArea) -> MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: area.latitude, longitude: area.longitude),
                           latitudinalMeters: squareMeters, longitudinalMeters: squareMeters)
    }

    private static func first(of request: MKLocalSearch.Request) async throws -> MKMapItem {
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { throw PlaceSearchError.noResult }
            return item
        } catch let error as PlaceSearchError {
            throw error
        } catch {
            throw map(error)
        }
    }

    /// MapKit and URL failures onto the cases the UI has copy for.
    private static func map(_ error: Error) -> PlaceSearchError {
        if let search = error as? PlaceSearchError { return search }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .dataNotAllowed: return .offline
            default: return .offline
            }
        }
        if let mk = error as? MKError {
            switch mk.code {
            case .loadingThrottled: return .throttled
            case .placemarkNotFound: return .noResult
            case .serverFailure, .unknown: return .offline
            default: return .noResult
            }
        }
        return .offline
    }

    private static func address(of item: MKMapItem) -> String? {
        nonEmpty(item.placemark.title ?? "")
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One completer per stream. The consumer cancels the stream to supersede the query; termination
    /// cancels the pending debounce and releases the completer.
    private func stream(query: String, configure: @escaping (MKLocalSearchCompleter) -> Void,
                        remember: @escaping ([String: MKLocalSearchCompletion]) -> Void) -> AsyncThrowingStream<[PlaceSuggestion], Error> {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return AsyncThrowingStream { continuation in
            guard trimmed.count >= 2 else {
                continuation.yield([])
                continuation.finish()
                return
            }
            let bridge = CompleterBridge()
            configure(bridge.completer)
            bridge.onResults = { completions in
                var byID: [String: MKLocalSearchCompletion] = [:]
                var rows: [PlaceSuggestion] = []
                for (index, completion) in completions.enumerated() {
                    let id = "\(index)|\(completion.title)|\(completion.subtitle)"
                    byID[id] = completion
                    rows.append(PlaceSuggestion(id: id, title: completion.title, subtitle: completion.subtitle))
                }
                remember(byID)
                continuation.yield(rows)
                continuation.finish()
            }
            bridge.onError = { error in continuation.finish(throwing: Self.map(error)) }
            let pending = Task { @MainActor in
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                bridge.completer.queryFragment = trimmed
            }
            continuation.onTermination = { _ in
                pending.cancel()
                Task { @MainActor in bridge.completer.cancel() }
            }
        }
    }
}

/// Bridges the completer's delegate callbacks to closures. Delegate methods arrive on the main thread.
private final class CompleterBridge: NSObject, MKLocalSearchCompleterDelegate {
    let completer = MKLocalSearchCompleter()
    var onResults: (([MKLocalSearchCompletion]) -> Void)?
    var onError: ((Error) -> Void)?

    override init() {
        super.init()
        completer.delegate = self
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { onResults?(completer.results) }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { onError?(error) }
}
