import SwiftUI
import FriendCalCore

@main
struct FriendCalApp: App {
    /// APNs registration and push taps (Poke, Tag along).
    @UIApplicationDelegateAdaptor(PushCoordinator.self) private var push

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
        // `-FriendCalTagAlong plan`: Leo hosts a locked "Tacos" tomorrow that you were sent and are not in.
        #if DEBUG
        let withPlan = UserDefaults.standard.string(forKey: "FriendCalTagAlong") == "plan"
        #else
        let withPlan = false
        #endif
        let fixture = withPlan ? FixtureData.withTagAlongPlan(fixture, now: FixtureClock.now()) : fixture
        let store = FixtureData.store(fixture, clock: FixtureClock.now)
        // `-FriendCalPokes inbox`: pokes already waiting, out and faded when the app opens.
        #if DEBUG
        if UserDefaults.standard.string(forKey: "FriendCalPokes") == "inbox" {
            FixtureData.seedPokes(into: store, fixture: fixture, now: FixtureClock.now())
        }
        #endif
        // The demo roster IS the demo friend graph, aligned to the Groups scenario that is on screen:
        // Groups reads friends from the store now, so the store and the screen must agree.
        if let me = store.currentUserID {
            let seed = GroupsSession.Seed.make(fixture: fixture, youID: me, scenario: .fromLaunchArguments, now: FixtureClock.now())
            store.setFriends(seed.friends.map(\.id), of: me)
        }
        // `-FriendCalSignedOut 1`: the fixture's data, nobody signed in (the gate shows).
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "FriendCalSignedOut") { store.forgetIdentity() }
        #endif
        // `-FriendCalFriendLink valid|dead|own|already`: what the store answers for the opened token.
        #if DEBUG
        store.friendLinkScenario = UserDefaults.standard.string(forKey: "FriendCalFriendLink").flatMap(InMemoryProposalStore.FriendLinkScenario.init(rawValue:))
        #endif
        let latency = UserDefaults.standard.double(forKey: "FriendCalStoreLatency")
        if latency > 0 { store.latency = .seconds(latency) }
        // `-FriendCalFailNext create|tapFree|lock|...`: that operation fails once with a network error.
        if let name = UserDefaults.standard.string(forKey: "FriendCalFailNext"),
           let op = InMemoryProposalStore.Operation.allCases.first(where: { "\($0)" == name }) {
            store.failNext[op] = ProposalStoreError.network("simulated failure (-FriendCalFailNext \(name))")
        }
        // `-FriendCalStaleNext vetoed|locked|removed`: the host's veto, the lock, or the suggester's withdrawal
        // lands on the server unseen, just before the viewer's next vote (reconcile tests, design 2.8A).
        if let name = UserDefaults.standard.string(forKey: "FriendCalStaleNext") {
            store.staleBeforeNextVote = InMemoryProposalStore.StaleChange(rawValue: name)
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
    /// The one owner of every opened link, above sign-in (spec 5).
    @State private var router = LinkRouter()

    var body: some Scene {
        WindowGroup {
            RootGateView(store: Self.store, fixture: Self.fixture, router: router)
                .environment(\.placeSearch, Self.placeSearch)
                .environment(router)
        }
    }
}

/// Identity-keyed root gate (G7): signedOut shows AuthGate, signedIn shows AppTabView keyed by userID.
/// It also owns the link router's lifetime: every opened URL goes to the router HERE, signed in or
/// not, and the pending link is cleared when the identity goes away (sign-out, account deletion).
struct RootGateView: View {
    let store: ProposalStore
    let fixture: HomeFixture
    let router: LinkRouter
    @StateObject private var model: AuthGateModel
    /// The account that was signed in, so its cached friend link can be cleared on the way out.
    @State private var lastAccount: UUID?

    init(store: ProposalStore, fixture: HomeFixture, router: LinkRouter) {
        self.store = store
        self.fixture = fixture
        self.router = router
        _model = StateObject(wrappedValue: AuthGateModel(store: store))
    }

    var body: some View {
        Group {
            switch model.state {
            case .signedOut, .failed, .signingIn:
                AuthGateView(auth: model, pending: pendingPill)
            case .signedIn(let id):
                AppTabView(fixture: fixture, store: store)
                    .id(id)
            }
        }
        .onOpenURL { router.open($0) }
        .onChange(of: model.state) { old, new in
            if case .signedIn(let id) = new { lastAccount = id }
            if case .signedIn = old, !new.isSignedIn {
                // Signed out or deleted: nothing pending, and the account's cached link goes too.
                router.clear()
                if let lastAccount { FriendLinkCache(persistent: true).clear(account: lastAccount) }
            }
        }
        .onAppear { if case .signedIn(let id) = model.state { lastAccount = id } }
    }

    /// What the sign-in gate says about the link waiting behind it.
    private var pendingPill: AuthGateView.Pending? {
        switch router.pending {
        case .proposal(_, let title): return title.map(AuthGateView.Pending.plan)
        case .friend(_, let name): return .friend(name)
        case nil: return nil
        }
    }
}
