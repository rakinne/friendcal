import SwiftUI
import FriendCalCore

@main
struct FriendCalApp: App {
    init() {
        #if DEBUG
        Self.assertFontsRegistered()
        #endif
    }

    #if DEBUG
    /// Fails loudly on a PostScript-name typo or an unregistered file instead
    /// of silently rendering SF Pro. Missing files already fail the build
    /// (font preBuildScript in project.yml).
    private static func assertFontsRegistered() {
        let missing = FontName.allCases.filter { UIFont(name: $0.rawValue, size: 12) == nil }
        assert(missing.isEmpty, "Fonts not registered: \(missing.map(\.rawValue)). Run scripts/fetch-fonts.sh and check UIAppFonts.")
    }
    #endif

    /// The store (issue #5 D7): `-FriendCalStore memory` forces the in-memory store (UI tests and
    /// previews); until the network store lands (PR2) it is the only store, behind the DEMO badge.
    /// `-FriendCalStoreLatency <seconds>` delays every operation so loading states can be seen;
    /// `-FriendCalFailNext <operation>` makes one operation fail once (error-path UI tests).
    private static func makeStore(fixture: HomeFixture) -> InMemoryProposalStore {
        let store = FixtureData.store(fixture, clock: FixtureClock.now)
        let latency = UserDefaults.standard.double(forKey: "FriendCalStoreLatency")
        if latency > 0 { store.latency = .seconds(latency) }
        // `-FriendCalFailNext create|tapFree|lock|...`: that operation fails once with a network error.
        if let name = UserDefaults.standard.string(forKey: "FriendCalFailNext"),
           let op = InMemoryProposalStore.Operation.allCases.first(where: { "\($0)" == name }) {
            store.failNext[op] = ProposalStoreError.network("simulated failure (-FriendCalFailNext \(name))")
        }
        return store
    }

    /// The network store unless a launch argument or a missing config says otherwise: `-FriendCalStore
    /// memory` and any `-FriendCalFixture` (UI tests, previews) keep the in-memory store, and so does a
    /// build with no Supabase URL and key in Info.plist (fresh clones, CI).
    private static let network: SupabaseProposalStore? = {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "FriendCalStore") == "memory" || defaults.string(forKey: "FriendCalFixture") != nil { return nil }
        return SupabaseProposalStore.fromBundle()
    }()
    /// Home still reads a fixture for its group header; against the network store that is the empty
    /// one, so no demo friends appear next to real plans.
    private static let fixture = FixtureData.make(network == nil ? .fromLaunchArguments : .noFriends, now: FixtureClock.now())
    private static let store: any ProposalStore = network ?? makeStore(fixture: fixture)
    /// Place and city search (#14): MapKit, or `-FriendCalSearch fixture` for UI tests.
    private static let placeSearch = PlaceSearchProvider.fromLaunchArguments()

    @StateObject private var authGate = AuthGateModel(store: Self.store)

    var body: some Scene {
        WindowGroup {
            RootGateView(store: Self.store, fixture: Self.fixture, pendingTitle: pendingTitle)
                .environment(\.placeSearch, Self.placeSearch)
        }
    }

    private var pendingTitle: String? {
        // pending deep link title hint for 1E
        if let url = UserDefaults.standard.string(forKey: "FriendCalPendingLink").flatMap(URL.init(string:)), let link = DeepLink.parse(url) {
            if case .proposal(_, let t) = link { return t }
        }
        return nil
    }
}

/// Identity-keyed root gate (G7): signedOut shows AuthGate, signedIn shows AppTabView keyed by userID
struct RootGateView: View {
    let store: ProposalStore
    let fixture: HomeFixture
    let pendingTitle: String?
    @StateObject private var model: AuthGateModel

    init(store: ProposalStore, fixture: HomeFixture, pendingTitle: String?) {
        self.store = store
        self.fixture = fixture
        self.pendingTitle = pendingTitle
        _model = StateObject(wrappedValue: AuthGateModel(store: store))
    }

    var body: some View {
        Group {
            switch model.state {
            case .signedOut, .failed:
                AuthGateView(auth: model, pendingTitle: pendingTitle)
            case .signingIn:
                AuthGateView(auth: model, pendingTitle: pendingTitle)
            case .signedIn(let id):
                AppTabView(fixture: fixture, store: store)
                    .id(id)
                    .task {
                        // replay pending link once on transition to authenticated-with-usable-name
                        if let urlStr = UserDefaults.standard.string(forKey: "FriendCalPendingLink"), !UserDefaults.standard.bool(forKey: "FriendCalSuppressPendingLink") {
                            if let url = URL(string: urlStr), let link = DeepLink.parse(url) {
                                try? await store.join(link.proposalID)
                                UserDefaults.standard.removeObject(forKey: "FriendCalPendingLink")
                            }
                        }
                    }
            }
        }
    }
}
