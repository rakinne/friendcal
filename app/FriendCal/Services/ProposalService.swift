import Foundation

public enum ProposalLockError: Error, LocalizedError {
    case notEnoughCoverage(required: Double, actual: Double)
    case insufficientRecipients
    case cellNotInWindow
    public var errorDescription: String? {
        switch self {
        case .notEnoughCoverage(let req, let act): return "Need \(Int(req*100))% free, only \(Int(act*100))% on this date"
        case .insufficientRecipients: return "No recipients to lock"
        case .cellNotInWindow: return "That time is outside the proposal window"
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

    /// Lock to the cell `id` as it stands in `weeks` (pass freshly built weeks, so a stale cell can't
    /// lock). Throws cellNotInWindow for a missing or disabled cell (D4), insufficientRecipients when
    /// nobody was invited, and notEnoughCoverage when fewer than quorumThreshold of the recipients
    /// share one >= 60-min window (D12). The lock date is the common window's start.
    /// - Returns: the common window, which `AvailabilityService.promoteToBusy(window:...)` takes.
    @discardableResult
    public func lock(_ proposal: inout Proposal, to id: HeatmapCell.ID, in weeks: [HeatmapWeek], busyWriter: (Proposal, Date) -> [BusyBlock]) throws -> DateRange {
        guard let cell = weeks.lazy.flatMap(\.cells).first(where: { $0.id == id }), cell.isEnabled else {
            throw ProposalLockError.cellNotInWindow
        }
        guard cell.total > 0 else { throw ProposalLockError.insufficientRecipients }
        guard cell.coverage >= quorumThreshold, let window = cell.commonWindow else {
            throw ProposalLockError.notEnoughCoverage(required: quorumThreshold, actual: cell.coverage)
        }
        proposal.lockedDate = window.lowerBound
        proposal.status = .locked
        _ = busyWriter(proposal, window.lowerBound)
        return window
    }
}
