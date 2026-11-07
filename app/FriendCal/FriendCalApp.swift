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

    private static let fixture = FixtureData.make(.fromLaunchArguments, now: FixtureClock.now())
    private static let store = makeStore(fixture: fixture)

    var body: some Scene {
        WindowGroup {
            AppTabView(fixture: Self.fixture, store: Self.store)
        }
    }
}
