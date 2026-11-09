import SwiftUI
import FriendCalCore

/// Which `PlaceSearching` the app talks to (#14). MapKit is the default. UI tests pass
/// `-FriendCalSearch fixture` for the deterministic Austin search (no network) and
/// `-FriendCalSearchFailNext throttled|offline|noResult|outsideArea` to make the next search or resolve
/// fail once. Views read the provider from the environment and hold one searcher for their lifetime,
/// because `MapKitPlaceSearch` remembers the rows it returned so a tapped row can be resolved.
struct PlaceSearchProvider: Sendable {
    var make: @MainActor @Sendable () -> any PlaceSearching

    static let mapKit = PlaceSearchProvider { MapKitPlaceSearch() }
    static let fixture = PlaceSearchProvider { FixtureSearchHolder.shared }

    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> PlaceSearchProvider {
        defaults.string(forKey: "FriendCalSearch") == "fixture" ? .fixture : .mapKit
    }
}

/// One fixture searcher per launch, so a one-shot `failNext` is consumed by whichever screen searches first.
@MainActor
private enum FixtureSearchHolder {
    static let shared: FixturePlaceSearch = {
        let search = FixturePlaceSearch()
        switch UserDefaults.standard.string(forKey: "FriendCalSearchFailNext") {
        case "throttled": search.failNext = .throttled
        case "offline": search.failNext = .offline
        case "noResult": search.failNext = .noResult
        case "outsideArea": search.failNext = .outsideArea
        default: break
        }
        return search
    }()
}

private struct PlaceSearchProviderKey: EnvironmentKey {
    static let defaultValue = PlaceSearchProvider.mapKit
}

extension EnvironmentValues {
    var placeSearch: PlaceSearchProvider {
        get { self[PlaceSearchProviderKey.self] }
        set { self[PlaceSearchProviderKey.self] = newValue }
    }
}

/// Builds the searcher once per screen. `@State` keeps the box across body evaluations; the box is not
/// observable on purpose, nothing redraws when it fills.
@MainActor
final class SearcherBox {
    private var searcher: (any PlaceSearching)?

    func resolve(_ provider: PlaceSearchProvider) -> any PlaceSearching {
        if let searcher { return searcher }
        let made = provider.make()
        searcher = made
        return made
    }
}

/// The one mapping from a search failure to the sentence the design approved (copy rows "Search errors"
/// and "City picker errors"). `area` is nil for the city picker.
enum PlaceSearchCopy {
    static func message(for error: PlaceSearchError, areaName: String? = nil) -> String {
        let km = Int(SearchArea.radiusMeters / 1000)
        switch error {
        case .throttled: return "Searching too fast. Wait a moment and try again."
        case .offline: return "No connection. Check your internet and try again."
        case .noResult:
            if let areaName { return "No places found near \(areaName). Try another name." }
            return "No city found. Try another name."
        case .outsideArea: return "That's outside \(areaName ?? "the city"). Try a place within \(km) km."
        }
    }
}
