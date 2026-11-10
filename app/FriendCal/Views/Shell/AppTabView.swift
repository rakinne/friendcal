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
///
/// The shell also owns the one `SocialSession`: every tab's Poke and Tag along go through it, the
/// Pokes tab reads its inbox and wears its badge, and a tapped push is routed here (a poke opens
/// the Pokes tab and is acknowledged; a tag along opens the plan).
struct AppTabView: View {
    let store: ProposalStore
    let fixture: HomeFixture
    @State private var home: ProposalSession
    @State private var groups: GroupsSession
    @State private var social: SocialSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .fromLaunchArguments
    @State private var homePath: [UUID] = []
    @State private var invitesPath: [UUID] = []
    @State private var toast: ToastCenter

    /// One fixture feeds both the store and Home's session, so a re-fetch of the seeded rows
    /// compares equal and `lastUpdated` stays put (X12).
    init(fixture: HomeFixture, store: ProposalStore) {
        self.store = store
        self.fixture = fixture
        let toast = ToastCenter()
        _toast = State(initialValue: toast)
        _social = State(initialValue: SocialSession(store: store, toasts: toast, now: FixtureClock.now))
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
                    HomeView(session: home, social: social, onOpenInvite: { homePath = [$0] }, onCreated: show)
                        .navigationDestination(for: UUID.self) { id in
                            LockedInviteDestination(store: store, id: id, groupName: fixture.groupName, members: fixture.members,
                                                    clock: FixtureClock.now, onGoToInvites: { homePath = []; tab = .invites })
                        }
                }
            }
            Tab("Groups", systemImage: "person.2", value: .groups) {
                GroupsView(session: groups, social: social, onToast: { toast.show($0) }, onOpenPlan: openInvite)
            }
            Tab("Pokes", systemImage: "hand.wave", value: .pokes) {
                PokesView(social: social, onOpenPlan: openInvite, onGoToGroups: { tab = .groups })
            }
            .badge(social.badge)
            Tab("Invites", systemImage: "envelope", value: .invites) {
                InvitesView(store: store, path: $invitesPath, members: fixture.members, clock: FixtureClock.now)
            }
            Tab("Me", systemImage: "person.crop.circle", value: .me) { NavigationStack { MeView(store: store) } }
        }
        .tint(DesignTokens.Colors.primary)
        .toast(toast)
        .onOpenURL(perform: open)
        .task { await social.run() }
        .task {
            await social.startNotifications()
            followPendingPush()
            // `-FriendCalPushTap poke/<uuid>`: a UI test's stand-in for tapping a push.
            if let route = UserDefaults.standard.string(forKey: "FriendCalPushTap").flatMap(PushRoute.init(launchArgument:)) { follow(route) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .friendCalPushTapped)) { _ in followPendingPush() }
        .onReceive(NotificationCenter.default.publisher(for: .friendCalPushArrived)) { _ in Task { await social.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .friendCalDeviceToken)) { _ in
            if let token = PushCoordinator.deviceToken { Task { await social.registerDevice(token) } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await social.refresh() } } }
    }

    private func openInvite(_ id: UUID) {
        invitesPath = [id]
        tab = .invites
    }

    /// A push tapped before this shell existed (cold launch, or the sign-in screen) is still waiting.
    private func followPendingPush() {
        if let route = PushCoordinator.takePendingRoute() { follow(route) }
    }

    /// Tapping a poke's push IS the acknowledgement; tapping a tag along opens the plan it joined.
    private func follow(_ route: PushRoute) {
        switch route {
        case .poke(let id):
            tab = .pokes
            Task { await social.acknowledge(id, via: .push) }
        case .tagAlong(let proposalID):
            openInvite(proposalID)
            Task { await social.refresh() }
        }
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

/// Placeholder for a tab with no content yet. Unused since Pokes became real; kept for the next one.
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
