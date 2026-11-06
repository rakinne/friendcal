#if DEBUG
import SwiftUI
import FriendCalCore

/// Debug-only tools, opened by long-pressing the wordmark (issue #4 item 5). Holds the former
/// on-Home proposal harness: create a proposal, "tap free" days, lock the selected cell.
/// Compiled out of Release.
@Observable
final class DebugProposalModel {
    var proposal: Proposal?
    var slots: [AvailabilitySlot] = []
    var weeks: [HeatmapWeek] = []
    var visibleWeekID: Date?
    var selectedCellID: HeatmapCell.ID?
    var lastError: String?
    var availabilityService = AvailabilityService()
    var proposalService = ProposalService()

    func createFriendsgivemas(createdBy: UUID) {
        let dist = Distribution(mode: .newGroup, recipientIDs: [createdBy, UUID(), UUID(), UUID()])
        proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(45 * 86400)), createdBy: createdBy, distribution: dist)
        rebuild()
    }

    func tapFree(date: Date, userID: UUID) {
        guard let p = proposal else { return }
        let range = DateRange(lower: date, upper: date.addingTimeInterval(7200))
        switch availabilityService.tapFreeSlot(userID: userID, range: range, proposalID: p.id, expiresAt: Date().addingTimeInterval(86400), existingSlots: slots) {
        case .softHold(let slot): slots.append(slot)
        case .alreadyHeld: break
        }
        rebuild()
    }

    func lockSelected() {
        guard var p = proposal, let id = selectedCellID else { return }
        rebuild() // fresh `now`, so a hold that just expired can't count toward quorum
        do {
            let window = try proposalService.lock(&p, to: id, in: weeks) { _, _ in [] }
            proposal = p
            let (_, expiredIDs) = availabilityService.promoteToBusy(window: window, proposalID: p.id, recipientIDs: p.distribution.recipientIDs, slots: slots, now: Date())
            slots = slots.filter { !expiredIDs.contains($0.id) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showWeek(_ id: Date?) {
        visibleWeekID = id
        selectedCellID = HeatmapSelection.resolve(current: selectedCellID, week: visibleWeek)
    }

    func select(_ id: HeatmapCell.ID) { selectedCellID = id }

    var visibleWeek: HeatmapWeek? { weeks.first { $0.id == visibleWeekID } }

    private func rebuild() {
        guard let p = proposal else { return }
        weeks = HeatmapBuilder.weeks(slots: slots, window: p.window, recipientIDs: p.distribution.recipientIDs, proposalID: p.id, now: Date(), calendar: .current)
        if !weeks.contains(where: { $0.id == visibleWeekID }) { visibleWeekID = weeks.first?.id }
        selectedCellID = HeatmapSelection.resolve(current: selectedCellID, week: visibleWeek)
    }
}

struct DebugSheet: View {
    @State private var model = DebugProposalModel()
    private let currentUserID = UUID()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    if let p = model.proposal {
                        Text("\(p.title) · \(p.status.rawValue)").textStyle(.title)
                        HeatmapCard(title: p.title, content: .weeks(model.weeks), total: Set(p.distribution.recipientIDs).count,
                                    visibleWeekID: model.visibleWeekID, selectedCellID: model.selectedCellID,
                                    onShowWeek: model.showWeek, onSelect: model.select)
                        Button("Lock selected cell") { model.lockSelected() }
                            .buttonStyle(.borderedProminent).tint(DesignTokens.Colors.primary)
                        if let error = model.lastError {
                            Text(error).textStyle(.caption).foregroundStyle(DesignTokens.Colors.error)
                        }
                    } else {
                        Button("Create Friendsgivemas proposal") { model.createFriendsgivemas(createdBy: currentUserID) }
                            .buttonStyle(.borderedProminent).tint(DesignTokens.Colors.primary)
                    }
                    Divider()
                    Text("Tap free (2h from now, per day)").textStyle(.label)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                        ForEach(0..<9, id: \.self) { idx in
                            let d = Calendar.current.date(byAdding: .day, value: idx, to: Date())!
                            Button { model.tapFree(date: d, userID: currentUserID) } label: {
                                VStack { Text(d, style: .date).font(.caption2); Text("tap free").font(.caption2.bold()) }
                            }
                            .buttonStyle(.bordered).tint(DesignTokens.Colors.accent)
                        }
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

#Preview("Debug sheet") { DebugSheet() }
#endif
