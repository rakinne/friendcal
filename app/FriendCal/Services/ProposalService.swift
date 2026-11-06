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

    /// Lock with quorum check. Throws if heatmap row for `date` is below threshold.
    public func lock(_ proposal: inout Proposal, to date: Date, heatmapRows: [HeatmapRow], busyWriter: (Proposal, Date) -> [BusyBlock]) throws {
        guard let row = heatmapRows.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) else {
            proposal.lockedDate = date
            proposal.status = .locked
            _ = busyWriter(proposal, date)
            return
        }
        guard row.totalRecipients > 0 else { throw ProposalLockError.insufficientRecipients }
        guard row.coverage >= quorumThreshold else {
            throw ProposalLockError.notEnoughCoverage(required: quorumThreshold, actual: row.coverage)
        }
        proposal.lockedDate = date
        proposal.status = .locked
        _ = busyWriter(proposal, date)
    }

    /// Legacy overload without heatmap (permissive) for previews
    func lock(_ proposal: inout Proposal, to date: Date, busyWriter: (Proposal, Date) -> [BusyBlock]) {
        try? lock(&proposal, to: date, heatmapRows: [], busyWriter: busyWriter)
    }
}
