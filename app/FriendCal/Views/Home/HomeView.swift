import SwiftUI
import FriendCalCore

/// Home (issue #4): header, wheel, heatmap card, chips, actions, stealth, with 20pt margins and
/// the D29 module gaps (8 / 12 / 12 / 16 / 12). Everything fits above the tab bar on iPhone 17 at
/// default Dynamic Type (D17); larger sizes scroll.
struct HomeView: View {
    var model: HomeModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var toast = ToastCenter()
    @State private var showDrawer = false
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
                    FriendStatusChips(content: chips, calendar: model.calendar).padding(.top, 12)
                }
                ActionRow(isLoading: model.isLoading, shareText: model.shareText,
                          shareDisabledHint: model.shareDisabledHint,
                          onPoke: { toast.show("Poke is coming soon") })
                    .padding(.top, 16)
                StealthRow(isLoading: model.isLoading, onTap: { toast.show("Stealth is coming soon. Nothing is hidden yet.") })
                    .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .toast(toast)
        // X12: recount on the minute and on return to foreground so expired holds drop out.
        .onReceive(minuteTick) { model.refresh(now: $0) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh(now: .now) } }
        .sheet(isPresented: $showDrawer) {
            MembersDrawer(groupName: model.groupName, members: model.members, roster: model.chips == nil ? nil : model.selectedCell?.roster,
                          calendar: model.calendar, isLoading: model.isLoading)
                .presentationDetents([.medium, .large])
        }
        #if DEBUG
        .sheet(isPresented: $showDebug) { DebugSheet() }
        #endif
    }

    // MARK: Modules

    /// Wordmark and group pill side by side; stacked when that would truncate the pill at large
    /// Dynamic Type sizes (D31: text outside the heatmap and wheel scales fully).
    private var header: some View {
        let pill = GroupPickerPill(name: model.groupName, members: model.members, isLoading: model.isLoading).fixedSize()
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
            content: model.isLoading ? .loading : .members(faces: model.wheel.faces, overflow: model.wheel.overflow, onlineCount: model.onlineCount),
            status: { member in
                model.selectedCell?.roster[member.id]?.word(calendar: model.calendar) ?? (member.isOnline ? "online" : "away")
            },
            onMore: { showDrawer = true },
            onInvite: { toast.show("Inviting friends is coming soon") }
        )
    }

    private var heatmap: some View {
        HeatmapCard(
            content: model.isLoading ? .loading : (model.proposal == nil ? .noProposal : .weeks(model.weeks)),
            total: model.total,
            visibleWeekID: model.visibleWeekID,
            selectedCellID: model.selectedCellID,
            lastUpdated: model.lastUpdated,
            calendar: model.calendar,
            onShowWeek: model.showWeek,
            onSelect: model.select,
            onRequestTimes: { toast.show("Requesting times is coming soon") }
        )
    }

    /// Loading draws skeleton chips; no selection hides the row and its gap (D19).
    private var chipsContent: FriendStatusChips.Content? {
        if model.isLoading { return .loading }
        return model.chips.map { .chips($0) }
    }
}

#Preview("Home, populated") { HomeView(model: HomeModel(fixture: FixtureData.make(.populated))) }
#Preview("Home, loading") { HomeView(model: HomeModel(fixture: FixtureData.make(.loading))) }
#Preview("Home, empty") { HomeView(model: HomeModel(fixture: FixtureData.make(.noFriends))) }
#Preview("Home, no proposal") { HomeView(model: HomeModel(fixture: FixtureData.make(.noProposal))) }
#Preview("Home, zero overlap") { HomeView(model: HomeModel(fixture: FixtureData.make(.zeroOverlap))) }
#Preview("Home, few friends") { HomeView(model: HomeModel(fixture: FixtureData.make(.fewFriends))) }
#Preview("Home, 0-count cell selected") {
    // X10: a tapped cell with nobody in common stays selected, chips show everyone busy,
    // Share is disabled with "Nobody shares an hour here yet".
    let model = HomeModel(fixture: FixtureData.make(.zeroOverlap))
    if let cell = model.visibleWeek?.cells.first(where: \.isEnabled) { model.select(cell.id) }
    return HomeView(model: model)
}
#Preview("Home, stale") { HomeView(model: HomeModel(fixture: FixtureData.make(.stale))) }
