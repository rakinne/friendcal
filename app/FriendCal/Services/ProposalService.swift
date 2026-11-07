import Foundation

public enum ProposalLockError: Error, LocalizedError, Equatable {
    case notEnoughCoverage(required: Double, actual: Double)
    case insufficientRecipients
    case cellNotInWindow
    /// The chosen duration clipped to the common span is under 60 minutes (issue #5 D14).
    case windowTooShort
    public var errorDescription: String? {
        switch self {
        case .notEnoughCoverage(let req, let act): return "Need \(Int(req*100))% free, only \(Int(act*100))% on this date"
        case .insufficientRecipients: return "No recipients to lock"
        case .cellNotInWindow: return "That time is outside the proposal window"
        case .windowTooShort: return "Everyone's free for less than an hour here"
        }
    }
}

/// Proposal lifecycle: create → distribute (Send Separately / New Group) → collect availability → heatmap → lock
public final class ProposalService {
    public init() {}

    /// Minimum coverage to allow lock. 0.5 = at least half; 1.0 = unanimous. Default 0.8 for founding group tight-knit vibe.
    /// Fixed, not configurable: lock_proposal() (supabase/lock_proposal.sql) enforces the same 0.8
    /// server-side, and ProposalTests pins the two together.
    public static let quorumThreshold: Double = 0.8
    public var quorumThreshold: Double { Self.quorumThreshold }

    /// The lock sheet's durations (D14, design 5.3A): 1 h, 1.5 h, 2 h, 3 h; default 2 h.
    public static let durations: [TimeInterval] = [3600, 5400, 7200, 10800]
    public static let defaultDuration: TimeInterval = 7200

    /// Validates a lock on `cell` and returns the window to send to the store (C5: pure, nothing is
    /// mutated; the store answers first, R3). Throws cellNotInWindow for a disabled cell (D4),
    /// insufficientRecipients when nobody was invited, notEnoughCoverage when fewer than
    /// quorumThreshold of the crew share one >= 60-min window (D12), and windowTooShort when the
    /// clipped window is under 60 minutes (D14).
    ///
    /// The window starts at the common window's start (#4 D12) and runs `duration` (nil = the whole
    /// common span, the lock sheet's "All"), clipped to the common span (D14, the server-side safety
    /// net under D22). Its start is rounded down and its end up to whole minutes (D18): the Supabase
    /// client truncates Dates at milliseconds, and a start a hair below a hold's bound would drop
    /// that recipient's promotion. The server mirrors every rule and also refuses a plan with fewer
    /// than 2 recipients (D13); `InMemoryProposalStore.lock` does too.
    public func validateLock(cell: HeatmapCell, duration: TimeInterval?) throws -> DateRange {
        guard cell.isEnabled else { throw ProposalLockError.cellNotInWindow }
        guard cell.total > 0 else { throw ProposalLockError.insufficientRecipients }
        guard cell.coverage >= quorumThreshold, let common = cell.commonWindow else {
            throw ProposalLockError.notEnoughCoverage(required: quorumThreshold, actual: cell.coverage)
        }
        let lower = Self.floorToMinute(common.lowerBound)
        let rawUpper = duration.map { min(lower.addingTimeInterval($0), common.upperBound) } ?? common.upperBound
        let window = DateRange(lower: lower, upper: Self.ceilToMinute(rawUpper))
        guard window.upperBound.timeIntervalSince(window.lowerBound) >= HeatmapBuilder.minimumCommonDuration else {
            throw ProposalLockError.windowTooShort
        }
        return window
    }

    /// Writes a lock the store confirmed onto the proposal (C5).
    public static func apply(window: DateRange, to proposal: inout Proposal, attendees: [UUID], at lockedAt: Date) {
        proposal.lockedDate = window.lowerBound
        proposal.lockedEnd = window.upperBound
        proposal.status = .locked
        proposal.lockedAttendeeIDs = attendees
        proposal.lockedAt = lockedAt
    }

    /// Lock to the cell `id` as it stands in `weeks` (pass freshly built weeks, so a stale cell can't
    /// lock) over the whole common window, applying the lock locally: `validateLock` then `apply`.
    /// `busyWriter` receives the whole locked window, not just its start, so a backend can persist
    /// both ends and promote in one transaction.
    /// - Returns: the common window, which `AvailabilityService.promoteToBusy(window:...)` takes.
    @discardableResult
    public func lock(_ proposal: inout Proposal, to id: HeatmapCell.ID, in weeks: [HeatmapWeek], busyWriter: (Proposal, DateRange) -> [BusyBlock]) throws -> DateRange {
        guard let cell = weeks.lazy.flatMap(\.cells).first(where: { $0.id == id }) else {
            throw ProposalLockError.cellNotInWindow
        }
        let window = try validateLock(cell: cell, duration: nil)
        Self.apply(window: window, to: &proposal, attendees: [], at: window.lowerBound)
        let promoted = busyWriter(proposal, window)
        proposal.lockedAttendeeIDs = promoted.map(\.userID)
        return window
    }

    static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    static func ceilToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
    }
}
