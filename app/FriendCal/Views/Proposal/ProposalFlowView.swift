import SwiftUI
import FriendCalCore

@Observable
final class ProposalFlowModel {
    var proposal: Proposal?
    var slots: [AvailabilitySlot] = []
    var weeks: [HeatmapWeek] = []
    var availabilityService = AvailabilityService()
    var proposalService = ProposalService()

    func createFriendsgivemas(createdBy: UUID) {
        let dist = Distribution(mode: .newGroup, recipientIDs: [createdBy, UUID(), UUID(), UUID()])
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

    func lock(to id: HeatmapCell.ID) throws {
        guard var p = proposal else { return }
        rebuildHeatmap() // fresh `now`, so a hold that just expired can't count toward quorum
        let window = try proposalService.lock(&p, to: id, in: weeks) { _, _ in [] }
        proposal = p
        // Promote + expire via service (DB write in real SupabaseService)
        let (promoted, expiredIDs) = availabilityService.promoteToBusy(window: window, proposalID: p.id, recipientIDs: p.distribution.recipientIDs, slots: slots)
        slots = slots.filter { !expiredIDs.contains($0.id) }
        _ = promoted
    }

    private func rebuildHeatmap() {
        guard let p = proposal else { return }
        weeks = HeatmapBuilder.weeks(slots: slots, window: p.window, recipientIDs: p.distribution.recipientIDs, proposalID: p.id, now: Date(), calendar: .current)
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
                HeatmapView(weeks: model.weeks)
                Button("Lock best date") {
                    if let best = model.weeks.lazy.compactMap(\.best).first { try? model.lock(to: best.id) }
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
