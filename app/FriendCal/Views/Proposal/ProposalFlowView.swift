import SwiftUI
import FriendCalCore

@Observable
final class ProposalFlowModel {
    var proposal: Proposal?
    var slots: [AvailabilitySlot] = []
    var rows: [HeatmapRow] = []
    var availabilityService = AvailabilityService()
    var proposalService = ProposalService()

    func createFriendsgivemas(createdBy: UUID) {
        let dist = Distribution(mode: .newGroup, recipientIDs: [UUID(), UUID(), UUID()])
        proposal = Proposal(id: UUID(), title: "Friendsgivemas", window: DateRange(Date.now...Date.now.addingTimeInterval(45*86400)), createdBy: createdBy, distribution: dist)
        rebuildHeatmap()
    }

    func tapFree(date: Date, userID: UUID) {
        guard let p = proposal else { return }
        let range = DateRange(lower: date, upper: date.addingTimeInterval(7200))
        switch availabilityService.tapFreeSlot(userID: userID, range: range, proposalID: p.id, expiresAt: Date().addingTimeInterval(86400), existingSlots: slots) {
        case .softHold(let slot): slots.append(slot)
        case .alreadyHeld: break
        }
        rebuildHeatmap()
    }

    func lock(to date: Date) throws {
        guard var p = proposal else { return }
        try proposalService.lock(&p, to: date, heatmapRows: rows) { _, _ in [] }
        proposal = p
        // Promote + expire via service (DB write in real SupabaseService)
        let (promoted, expiredIDs) = availabilityService.promoteToBusy(onLock: date, proposalID: p.id, recipientIDs: p.distribution.recipientIDs, slots: slots)
        slots = slots.filter { !expiredIDs.contains($0.id) }
        _ = promoted
    }

    private func rebuildHeatmap() {
        guard let p = proposal else { return }
        // Group by day (simplified)
        let days = Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 7
        let total = max(p.distribution.recipientIDs.count, 1)
        var map: [Date: Int] = [:]
        for s in slots where !s.isExpired { map[s.range.lowerBound, default: 0] += 1 }
        rows = map.map { HeatmapRow(date: $0.key, freeCount: $0.value, totalRecipients: total) }.sorted { $0.date < $1.date }
    }
}

struct ProposalFlowView: View {
    @State var model = ProposalFlowModel()
    let currentUserID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let p = model.proposal {
                Text(p.title).font(.title3.bold()).foregroundStyle(DesignTokens.Colors.text)
                Text(p.window.lowerBound, style: .date).font(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                HeatmapView(rows: model.rows)
                Button("Lock best date") {
                    if let best = model.rows.max(by: { $0.coverage < $1.coverage }) { try? model.lock(to: best.date) }
                }
                .buttonStyle(.borderedProminent).tint(DesignTokens.Colors.primary)
            } else {
                Button("Create Friendsgivemas proposal") { model.createFriendsgivemas(createdBy: currentUserID) }
                    .buttonStyle(.borderedProminent).tint(DesignTokens.Colors.primary)
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                ForEach(0..<9, id: \.self) { idx in
                    let d = Calendar.current.date(byAdding: .day, value: idx, to: Date())!
                    Button { model.tapFree(date: d, userID: currentUserID) } label: {
                        VStack { Text(d, style: .date).font(.caption2); Text("tap free").font(.caption2.bold()) }
                    }
                    .buttonStyle(.bordered).tint(DesignTokens.Colors.accent)
                }
            }
        }
        .padding()
        .background(DesignTokens.Colors.background)
    }
}
