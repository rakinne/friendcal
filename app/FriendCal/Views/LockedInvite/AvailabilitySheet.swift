import SwiftUI
import FriendCalCore

/// "When are you free?" (issue #5 design 1.4A, 1.5A, 2.2A, 5.1A, 5.2A, 6.1A): the heatmap in
/// `.mark` mode where a tap toggles the user's hold for that cell (D9: expires at the slot's end;
/// past cells are quiet), chips for the last-toggled cell, the LockState caption pinned at the
/// bottom, and its own toast for a failed save. Haptics: `.impact(.light)` per toggle and
/// `.success` when the caption reaches quorum.
struct AvailabilitySheet: View {
    var session: ProposalSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toast = ToastCenter()
    @State private var taps = 0
    @State private var reached = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("When are you free?").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("availability.title")
                    Text("Tap the times you could make. Tap again to take one back.")
                        .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Text("Done").textStyle(.title).foregroundStyle(DesignTokens.Colors.accentHover)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("availability.done")
            }
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HeatmapCard(
                        title: nil,
                        content: .weeks(session.weeks),
                        mode: .mark(mine: session.myHoldCellIDs, now: session.now()),
                        total: session.total,
                        visibleWeekID: session.visibleWeekID,
                        lastUpdated: session.lastUpdated,
                        calendar: session.calendar,
                        onShowWeek: session.showWeek,
                        onSelect: toggle
                    )
                    if let chips = session.markChips {
                        FriendStatusChips(content: .chips(chips), calendar: session.calendar)
                            .id(session.markFocusCellID)
                            .transition(.opacity)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.markFocusCellID)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            if let state = session.lockState, let caption = state.caption(creatorName: session.creatorName, isCreator: session.isCreator) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").imageScale(.small).accessibilityHidden(true)
                    Text(caption).textStyle(.caption).accessibilityIdentifier("availability.caption")
                }
                .foregroundStyle(DesignTokens.Colors.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .toast(toast)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .sensoryFeedback(.success, trigger: reached) { _, now in now }
        .onChange(of: session.lockState?.isQuorumReached ?? false) { _, value in reached = value }
        .onAppear { reached = session.lockState?.isQuorumReached ?? false }
    }

    private func toggle(_ id: HeatmapCell.ID) {
        guard let cell = session.visibleWeek?.cells.first(where: { $0.id == id }) else { return }
        taps += 1
        Task {
            if let error = await session.toggle(cell) {
                toast.show(error.message, duration: ToastCenter.errorSeconds)
            }
        }
    }
}

#Preview("Availability sheet") {
    AvailabilitySheet(session: ProposalSession(fixture: FixtureData.make(.lockedInvite)))
}
