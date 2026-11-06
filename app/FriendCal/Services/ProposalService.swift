import Foundation

public enum ProposalLockError: Error, LocalizedError {
    case notEnoughCoverage(required: Double, actual: Double)
    case insufficientRecipients
    public var errorDescription: String? {
        switch self {
        case .notEnoughCoverage(let req, let act): return "Need \(Int(req*100))% free, only \(Int(act*100))% on this date"
        case .insufficientRecipients: return "No recipients to lock"
        }
    }
}

/// Proposal lifecycle: create → distribute (Send Separately / New Group) → collect availability → heatmap → lock
public final class ProposalService {
    public init() {}

    /// Minimum coverage to allow lock. 0.5 = at least half; 1.0 = unanimous. Default 0.8 for founding group tight-knit vibe.
    public var quorumThreshold: Double = 0.8

    func createProposal(title: String, window: DateRange, distribution: Distribution, createdBy: UUID) -> Proposal {
        Proposal(id: UUID(), title: title, window: window, createdBy: createdBy, distribution: distribution)
    }

    /// Lock to a heatmap cell. Quorum is checked against commonCount (D12, D13); the lock date is
    /// the start of the cell's common window.
    public func lock(_ proposal: inout Proposal, to cell: HeatmapCell, busyWriter: (Proposal, Date) -> [BusyBlock]) throws {
        guard cell.total > 0 else { throw ProposalLockError.insufficientRecipients }
        guard cell.coverage >= quorumThreshold, let date = cell.lockTarget else {
            throw ProposalLockError.notEnoughCoverage(required: quorumThreshold, actual: cell.coverage)
        }
        proposal.lockedDate = date
        proposal.status = .locked
        _ = busyWriter(proposal, date)
    }
}
