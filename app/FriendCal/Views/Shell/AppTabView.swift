import SwiftUI
import FriendCalCore

enum AppTab: String, Hashable {
    case home, groups, pokes, invites, me

    /// `-FriendCalTab groups` opens a tab directly (UI tests, screenshots); Home otherwise.
    static var fromLaunchArguments: AppTab {
        UserDefaults.standard.string(forKey: "FriendCalTab").flatMap(AppTab.init(rawValue:)) ?? .home
    }
}

/// Native iOS 26 TabView (Liquid Glass) with `Tab` items (D34, X3). Home content relies on the
/// automatic bottom safe-area inset, so the stealth row clears the floating bar. Issue #5: one
/// store for every tab (D2), Home and Invites each in a NavigationStack that pushes the invite,
/// `onOpenURL` routes `friendcal://proposal/<id>` to the Invites tab (D3, design 1.7A).
struct AppTabView: View {
    let store: ProposalStore
    let fixture: HomeFixture
    @State private var home: ProposalSession
    @State private var groups: GroupsSession
    @State private var tab: AppTab = .fromLaunchArguments
    @State private var homePath: [UUID] = []
    @State private var invitesPath: [UUID] = []
    @State private var toast = ToastCenter()

    /// One fixture feeds both the store and Home's session, so a re-fetch of the seeded rows
    /// compares equal and `lastUpdated` stays put (X12).
    init(fixture: HomeFixture, store: ProposalStore) {
        self.store = store
        self.fixture = fixture
        _home = State(initialValue: ProposalSession(store: store, fixture: fixture, now: FixtureClock.now))
        _groups = State(initialValue: GroupsSession(
            seed: .make(fixture: fixture, youID: store.currentUserID, scenario: .fromLaunchArguments, now: FixtureClock.now()),
            now: FixtureClock.now))
    }

    init(scenario: FixtureScenario = .fromLaunchArguments) {
        let fixture = FixtureData.make(scenario, now: FixtureClock.now())
        self.init(fixture: fixture, store: FixtureData.store(fixture, clock: FixtureClock.now))
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: .home) {
                NavigationStack(path: $homePath) {
                    HomeView(session: home, onOpenInvite: { homePath = [$0] }, onCreated: show)
                        .navigationDestination(for: UUID.self) { id in
                            LockedInviteDestination(store: store, id: id, groupName: fixture.groupName, members: fixture.members,
                                                    clock: FixtureClock.now, onGoToInvites: { homePath = []; tab = .invites })
                        }
                }
            }
            Tab("Groups", systemImage: "person.2", value: .groups) { GroupsView(session: groups, onToast: { toast.show($0) }) }
            Tab("Pokes", systemImage: "hand.wave", value: .pokes) { StubTabView(title: "Pokes") }
            Tab("Invites", systemImage: "envelope", value: .invites) {
                InvitesView(store: store, path: $invitesPath, members: fixture.members, clock: FixtureClock.now)
            }
            Tab("Me", systemImage: "person.crop.circle", value: .me) { NavigationStack { MeView(store: store) } }
        }
        .tint(DesignTokens.Colors.primary)
        .toast(toast)
        .onOpenURL(perform: open)
    }

    /// A new plan lands on its invite in the Invites tab (design 3.2A); Home adopts it as the group's plan.
    private func show(_ proposal: Proposal) {
        home.adopt(proposal.id)
        homePath = []
        invitesPath = [proposal.id]
        tab = .invites
    }

    /// Design 2.2A: an invalid link shows a 4s toast on the current screen.
    private func open(_ url: URL) {
        guard let link = DeepLink.parse(url) else {
            toast.show("That link isn't a FriendCal invite", duration: ToastCenter.errorSeconds)
            return
        }
        switch link {
        case .proposal(let id, _):
            tab = .invites
            invitesPath = [id]
        }
    }
}

/// Placeholder for tabs whose content is out of scope for issue #4.
struct StubTabView: View {
    let title: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text(title).textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)
            Text("Coming soon").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .accessibilityIdentifier("stub.\(title.lowercased())")
    }
}

#Preview("Shell") { AppTabView(scenario: .populated) }
#Preview("Shell, invite") { AppTabView(scenario: .lockedInvite) }
#Preview("Stub tab") { StubTabView(title: "Pokes") }
