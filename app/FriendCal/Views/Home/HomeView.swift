import SwiftUI
import FriendCalCore

/// Home (issue #4): header, wheel, heatmap card, chips, actions, stealth, with 20pt margins and
/// the D29 module gaps (8 / 12 / 12 / 16 / 12). Everything fits above the tab bar on iPhone 17 at
/// default Dynamic Type (D17); larger sizes scroll. Issue #5: a view over `ProposalSession`; the
/// heatmap header links to the invite, Request times opens the create sheet, a locked plan shows
/// its cell and "in" chips, and the DEMO badge sits inside the header row on the in-memory store.
struct HomeView: View {
    var session: ProposalSession
    /// Poke goes through the shared session, like every other Poke in the app.
    let social: SocialSession
    /// Push the invite for this proposal (design 1.1A).
    var onOpenInvite: (UUID) -> Void = { _ in }
    /// A plan was created from Request times: the shell shows it on the Invites tab (design 3.2A).
    var onCreated: (Proposal) -> Void = { _ in }
    /// Opens Add a friend (the shell owns the sheet). Reachable from the debug sheet only until PR 3.
    var onAddFriend: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @State private var toast = ToastCenter()
    @State private var showDrawer = false
    @State private var showCreate = false
    @State private var showPoke = false
    /// Held in state so redraws don't resubscribe and restart the 60s countdown (X12).
    @State private var minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    #if DEBUG
    @State private var showDebug = false
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header.frame(minHeight: 44)
                wheel.padding(.top, 8)
                heatmap.padding(.top, 12)
                if let chips = chipsContent {
                    FriendStatusChips(content: chips, calendar: session.calendar).padding(.top, 12)
                }
                ActionRow(isLoading: session.isLoading, shareText: session.shareText,
                          shareDisabledHint: session.shareDisabledHint,
                          onPoke: { showPoke = true })
                    .padding(.top, 16)
                StealthRow(isLoading: session.isLoading, onTap: { toast.show("Stealth is coming soon. Nothing is hidden yet.") })
                    .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .toast(toast)
        // X12: recount on the minute and on return to foreground so expired holds drop out; the
        // session also re-fetches on foreground (issue #5 C8).
        .onReceive(minuteTick) { _ in session.tick() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { session.tick(); Task { await session.reload() } } }
        .task(id: session.proposalID) { await session.run() }
        .sheet(isPresented: $showDrawer) {
            MembersDrawer(groupName: session.groupName, members: session.members, roster: session.chips == nil ? nil : session.selectedCell?.roster,
                          calendar: session.calendar, isLoading: session.isLoading)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPoke) {
            PokePickerSheet(social: social, targets: pokeTargets, planID: session.proposal?.id, planTitle: session.proposal?.displayTitle,
                            faces: Dictionary(session.members.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
                .presentationDetents([.medium, .large])
                .presentationBackground(DesignTokens.Colors.background)
        }
        .sheet(isPresented: $showCreate) {
            CreateProposalSheet(mode: .create(session.store, calendar: session.calendar, now: session.now), onCreated: onCreated)
                .presentationDetents([.large])
        }
        #if DEBUG
        .sheet(isPresented: $showDebug) { DebugSheet(session: session, onAddFriend: onAddFriend) }
        #endif
    }

    /// Everyone on the plan but you, the ones who have not picked a time first. Only the host can
    /// tell who that is: a recipient reads only their own holds (rls.sql section 3), so to anyone
    /// else every friend would look silent, and the sheet says nothing rather than something false.
    private var pokeTargets: [PokeTarget] {
        PokeTarget.order(members: session.members.map { (id: $0.id, name: $0.name) },
                         answered: Set(session.slots.map(\.userID)), me: session.currentUserID,
                         isCollecting: session.proposal?.status == .requesting && session.isCreator)
    }

    // MARK: Modules

    /// Wordmark and group pill side by side; stacked when that would truncate the pill at large
    /// Dynamic Type sizes (D31: text outside the heatmap and wheel scales fully).
    private var header: some View {
        let pill = GroupPickerPill(name: session.groupName, members: session.members, isLoading: session.isLoading, isDemo: session.isDemo).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack {
                wordmark
                Spacer(minLength: DesignTokens.Spacing.sm)
                pill
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                wordmark
                pill
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var wordmark: some View {
        BrandWordmark()
        #if DEBUG
            .onLongPressGesture { showDebug = true }
            .accessibilityAction(named: "Open debug tools") { showDebug = true }
            .accessibilityIdentifier("home.wordmark")
        #endif
    }

    private var wheel: some View {
        FriendsWheel(
            content: session.isLoading ? .loading : .members(faces: session.wheel.faces, overflow: session.wheel.overflow, onlineCount: session.onlineCount),
            status: { member in
                if let p = session.proposal, p.isLocked { return p.lockedAttendeeIDs.contains(member.id) ? "in" : "out" }
                return session.selectedCell?.roster[member.id]?.word(calendar: session.calendar) ?? (member.isOnline ? "online" : "away")
            },
            onMore: { showDrawer = true },
            onInvite: { toast.show("Inviting friends is coming soon") }
        )
    }

    private var heatmap: some View {
        HeatmapCard(
            content: session.isLoading ? .loading : (session.proposal == nil ? .noProposal : .weeks(session.weeks)),
            total: session.total,
            visibleWeekID: session.visibleWeekID,
            selectedCellID: session.selectedCellID,
            lockedCellID: session.lockedCellID,
            lastUpdated: session.lastUpdated,
            calendar: session.calendar,
            onShowWeek: session.showWeek,
            onSelect: session.select,
            onRequestTimes: { showCreate = true },
            onOpenInvite: session.proposalID.map { id in { onOpenInvite(id) } }
        )
    }

    /// Loading draws skeleton chips; no selection hides the row and its gap (D19); a locked plan
    /// reads attendance from the proposal row (design 2.2A).
    private var chipsContent: FriendStatusChips.Content? {
        if session.isLoading { return .loading }
        if let attendees = session.attendeeChips { return .attendees(attendees) }
        return session.chips.map { .chips($0) }
    }
}

#Preview("Home, populated") { HomeView(session: ProposalSession(fixture: FixtureData.make(.populated)), social: .preview(.populated)) }
#Preview("Home, loading") { HomeView(session: ProposalSession(fixture: FixtureData.make(.loading)), social: .preview(.loading)) }
#Preview("Home, empty") { HomeView(session: ProposalSession(fixture: FixtureData.make(.noFriends)), social: .preview(.noFriends)) }
#Preview("Home, no proposal") { HomeView(session: ProposalSession(fixture: FixtureData.make(.noProposal)), social: .preview(.noProposal)) }
#Preview("Home, zero overlap") { HomeView(session: ProposalSession(fixture: FixtureData.make(.zeroOverlap)), social: .preview(.zeroOverlap)) }
#Preview("Home, few friends") { HomeView(session: ProposalSession(fixture: FixtureData.make(.fewFriends)), social: .preview(.fewFriends)) }
#Preview("Home, locked") { HomeView(session: ProposalSession(fixture: FixtureData.make(.lockedPlan)), social: .preview(.lockedPlan)) }
#Preview("Home, 0-count cell selected") {
    // X10: a tapped cell with nobody in common stays selected, chips show everyone busy,
    // Share is disabled with "Nobody shares an hour here yet".
    let model = ProposalSession(fixture: FixtureData.make(.zeroOverlap))
    if let cell = model.visibleWeek?.cells.first(where: \.isEnabled) { model.select(cell.id) }
    return HomeView(session: model, social: .preview(.zeroOverlap))
}
#Preview("Home, stale") { HomeView(session: ProposalSession(fixture: FixtureData.make(.stale)), social: .preview(.stale)) }
