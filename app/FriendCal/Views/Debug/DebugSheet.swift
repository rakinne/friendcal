#if DEBUG
import SwiftUI
import FriendCalCore

/// Debug-only tools, opened by long-pressing the wordmark (issue #4 item 5). A view over the Home
/// session (issue #5 S1: the former DebugProposalModel is gone, so the harness can't drift from
/// Home): toggle your hold on the selected cell, lock the best cell for 2 h, see the store's answer.
/// Compiled out of Release.
struct DebugSheet: View {
    var session: ProposalSession
    @State private var lastError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    if let p = session.proposal {
                        Text("\(p.displayTitle) · \(p.status.rawValue) · \(session.isCreator ? "you host" : "hosted by \(session.creatorName ?? "?")")").textStyle(.title)
                        HeatmapCard(title: p.title, content: .weeks(session.weeks), total: session.total,
                                    visibleWeekID: session.visibleWeekID, selectedCellID: session.selectedCellID, lockedCellID: session.lockedCellID,
                                    calendar: session.calendar, onShowWeek: session.showWeek, onSelect: session.select)
                        if let state = session.lockState {
                            Text(String(describing: state)).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        }
                        Button("Toggle my hold on the selected cell") {
                            guard let cell = session.selectedCell else { return }
                            Task { lastError = await session.toggle(cell)?.message }
                        }
                        .buttonStyle(.bordered).tint(DesignTokens.Colors.accent)
                        Button("Lock the best cell (2 h)") {
                            Task {
                                do { try await session.lock(duration: ProposalService.defaultDuration); lastError = nil }
                                catch { lastError = (error as? UserFacingError)?.message ?? error.localizedDescription }
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(DesignTokens.Colors.primary)
                        if let error = lastError {
                            Text(error).textStyle(.caption).foregroundStyle(DesignTokens.Colors.error)
                        }
                    } else {
                        Text("No proposal. Use Request times on Home.").textStyle(.body)
                    }
                    Divider()
                    Text("BusyBlockView sample").textStyle(.label)
                    BusyBlockView(sanitized: StealthService.SanitizedBusy(id: UUID(), userID: UUID(), range: DateRange(lower: Date.now, upper: Date.now.addingTimeInterval(3600))))
                }
                .padding(20)
            }
            .background(DesignTokens.Colors.background.ignoresSafeArea())
            .navigationTitle("Debug").navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview("Debug sheet") { DebugSheet(session: ProposalSession(fixture: FixtureData.make(.lockedInviteCreator))) }
#endif
