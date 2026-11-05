import Foundation

/// Proposal lifecycle: create → distribute (Send Separately / New Group) → collect availability → heatmap → lock
final class ProposalService {
    func createProposal(title: String, window: DateRange, distribution: Distribution, createdBy: UUID) -> Proposal {
        Proposal(id: UUID(), title: title, window: window, createdBy: createdBy, distribution: distribution)
    }

    func lock(_ proposal: inout Proposal, to date: Date, busyWriter: (Proposal, Date) -> [BusyBlock]) {
        proposal.lockedDate = date
        proposal.status = .locked
        _ = busyWriter(proposal, date) // writes BusyBlocks, stealth-aware via StealthService
    }
}
