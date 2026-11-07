import Foundation

/// The one number behind the invite caption, its VoiceOver text, the Lock control and the settled
/// card (issue #5 S3, R5). Derived from the proposal row and the heatmap; never stored.
///
/// `needed = ceil(threshold x total)` with `total = max(expectedCount, joined)` (D13) and
/// `have = max commonCount` over every enabled cell; the same rule as `ProposalService` and
/// lock_proposal.sql, so the caption never promises a lock the server refuses.
public enum LockState: Equatable {
    /// Only the creator is on the plan (design 1.1A): "No one has joined yet", Invite friends.
    case inviteFriends(expected: Int)
    /// Collecting availability. `bestCell` is the cell behind `have` (earliest wins ties).
    case requesting(have: Int, needed: Int, total: Int, joined: Int, bestCell: HeatmapCell?)
    /// Settled (C1): attendees come from the proposal row, never from busy_blocks (X1).
    /// `joinedAfterLock` are viewers who opened the link after the lock (delta O1).
    case locked(window: DateRange, attendees: [UUID], joinedAfterLock: [UUID])

    public static func make(proposal: Proposal, weeks: [HeatmapWeek], threshold: Double = ProposalService.quorumThreshold) -> LockState {
        if proposal.status == .locked, let window = proposal.lockedWindow {
            return .locked(window: window, attendees: proposal.lockedAttendeeIDs, joinedAfterLock: proposal.postLockRecipientIDs)
        }
        let joined = proposal.joinedCount
        if joined <= 1 { return .inviteFriends(expected: proposal.expectedCount) }
        let total = max(proposal.expectedCount, joined)
        var best: HeatmapCell?
        for week in weeks {
            for cell in week.cells where cell.isEnabled && cell.commonCount > 0 {
                if best == nil || cell.commonCount > best!.commonCount { best = cell }
            }
        }
        return .requesting(have: best?.commonCount ?? 0, needed: needed(total: total, threshold: threshold), total: total, joined: joined, bestCell: best)
    }

    /// ceil(threshold x total), with a tolerance so an exact multiple (0.8 x 10) never rounds up to 9.
    public static func needed(total: Int, threshold: Double = ProposalService.quorumThreshold) -> Int {
        max(1, Int((threshold * Double(total) - 1e-9).rounded(.up)))
    }

    public var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }

    /// have >= needed (inclusive, like ProposalService.quorumThreshold).
    public var isQuorumReached: Bool {
        guard case .requesting(let have, let needed, _, _, _) = self else { return false }
        return have >= needed
    }

    /// Friends still missing from the best cell; 0 once quorum is reached.
    public var remaining: Int {
        guard case .requesting(let have, let needed, _, _, _) = self else { return 0 }
        return max(0, needed - have)
    }

    public var bestCell: HeatmapCell? {
        guard case .requesting(_, _, _, _, let cell) = self else { return nil }
        return cell
    }
}
