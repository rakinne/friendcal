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
/// links arrive through the `LinkRouter` above sign-in: a plan link lands on its invite in the
/// Invites tab (D3, design 1.7A), a friend link opens the Accept cover.
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
    @Environment(LinkRouter.self) private var router: LinkRouter?
    /// The Accept cover, for the friend link being answered.
    @State private var accept: AcceptRequest?
    /// The Add a friend sheet (reachable from the debug sheet only until the entry points ship).
    @State private var friendSheet: FriendLinkSession?
    @State private var linkCache: FriendLinkCache
    @State private var wasInBackground = false

    private struct AcceptRequest: Identifiable {
        let id = UUID()
        let generation: Int
        let flow: FriendAcceptFlow
    }

    /// One fixture feeds both the store and Home's session, so a re-fetch of the seeded rows
    /// compares equal and `lastUpdated` stays put (X12).
    init(fixture: HomeFixture, store: ProposalStore) {
        self.store = store
        self.fixture = fixture
        let toast = ToastCenter()
        _toast = State(initialValue: toast)
        _social = State(initialValue: SocialSession(store: store, toasts: toast, now: FixtureClock.now))
        _home = State(initialValue: ProposalSession(store: store, fixture: fixture, now: FixtureClock.now))
        let persistent = store is SupabaseProposalStore
        _linkCache = State(initialValue: FriendLinkCache(persistent: persistent))
        _groups = State(initialValue: GroupsSession(
            seed: .make(fixture: fixture, youID: store.currentUserID, scenario: .fromLaunchArguments, now: FixtureClock.now()),
            store: store, knownStore: KnownFriendsStore(persistent: persistent), now: FixtureClock.now))
    }

    init(scenario: FixtureScenario = .fromLaunchArguments) {
        let fixture = FixtureData.make(scenario, now: FixtureClock.now())
        self.init(fixture: fixture, store: FixtureData.store(fixture, clock: FixtureClock.now))
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: .home) {
                NavigationStack(path: $homePath) {
                    HomeView(session: home, social: social, onOpenInvite: { homePath = [$0] }, onCreated: show, onAddFriend: openAddFriend)
                        .navigationDestination(for: UUID.self) { id in
                            LockedInviteDestination(store: store, id: id, groupName: fixture.groupName, members: fixture.members,
                                                    clock: FixtureClock.now, onGoToInvites: { homePath = []; tab = .invites })
                        }
                }
            }
            Tab("Groups", systemImage: "person.2", value: .groups) {
                GroupsView(session: groups, social: social, onToast: { toast.show($0) }, onOpenPlan: openInvite)
            }
            // The same count badge the Pokes tab wears: friends who arrived while another tab was up.
            .badge(groups.arrivalCount)
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
        .task(id: router?.generation) { await followPendingLink() }
        .onChange(of: router?.invalidCount) { _, _ in
            toast.show("That link isn't a FriendCal invite", duration: ToastCenter.errorSeconds)
        }
        .onChange(of: groups.friends) { _, _ in syncWheelFaces() }
        .onAppear { syncWheelFaces() }
        .fullScreenCover(item: $accept) { request in acceptCover(request) }
        .sheet(item: $friendSheet) { session in
            AddFriendSheet(session: session, onDone: { friendSheet = nil })
        }
        .task { await groups.refresh() }
        .task { await social.run() }
        .task {
            await social.startNotifications()
            followPendingPush()
            // `-FriendCalPushTap poke/<uuid>`: a UI test's stand-in for tapping a push.
            #if DEBUG
            if let route = UserDefaults.standard.string(forKey: "FriendCalPushTap").flatMap(PushRoute.init(launchArgument:)) { follow(route) }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .friendCalPushTapped)) { _ in followPendingPush() }
        .onReceive(NotificationCenter.default.publisher(for: .friendCalPushArrived)) { _ in Task { await social.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .friendCalDeviceToken)) { _ in
            if let token = PushCoordinator.deviceToken { Task { await social.registerDevice(token) } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasInBackground = true }
            if phase == .active {
                Task { await social.refresh() }
                // The roster is read at launch; later it is read when the app returns from the background.
                if wasInBackground { wasInBackground = false; Task { await groups.refresh(force: true) } }
            }
        }
    }

    // MARK: Friends

    /// Home's wheel draws your friends when there is no plan.
    private func syncWheelFaces() {
        home.friendFaces = groups.friends.map { HomeMember(id: $0.id, name: $0.name, isOnline: $0.isOnline, isActive: false) }
    }

    private func openAddFriend() {
        Task {
            guard await PresentationGate.waitUntilClear(), let me = store.currentUserID else { return }
            friendSheet = FriendLinkSession(store: store, account: me, senderName: groups.you.name, cache: linkCache)
        }
    }

    /// The pending link, once someone is signed in. A plan link lands on its invite and joins (kept for
    /// a retry if the join failed on the network); a friend link waits for any open sheet to close and
    /// then opens Accept, which calls nothing but preview until Connect.
    private func followPendingLink() async {
        guard let router, let link = router.pending else { return }
        let generation = router.generation
        switch link {
        case .proposal(let id, _):
            tab = .invites
            invitesPath = [id]
            do {
                _ = try await store.join(id)
                router.finish(generation: generation)
            } catch ProposalStoreError.server {
                router.finish(generation: generation)   // the plan answered: gone, closed or hidden. Nothing to retry.
            } catch {
                // Network or identity: keep the link; the invite screen has its own retry.
            }
        case .friend(let token, _):
            guard accept == nil, await PresentationGate.waitUntilClear(), router.generation == generation, accept == nil else { return }
            let flow = FriendAcceptFlow(store: store, token: token) { [groups] id in groups.willConnect(id) }
            accept = AcceptRequest(generation: generation, flow: flow)
        }
    }

    private func acceptCover(_ request: AcceptRequest) -> some View {
        let me = groups.you
        return AcceptFriendView(
            flow: request.flow,
            me: HomeMember(id: me.id, name: me.name, isOnline: true, isActive: false),
            onConnected: { friend in
                router?.finish(generation: request.generation)
                accept = nil
                tab = .groups
                groups.connected(friend)
            },
            onNotNow: {
                router?.clear()
                accept = nil
            },
            onAnswered: { followup in
                router?.finish(generation: request.generation)
                accept = nil
                switch followup {
                case .ok: break
                case .openGroups: tab = .groups
                case .shareLink: openAddFriend()
                }
            })
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
