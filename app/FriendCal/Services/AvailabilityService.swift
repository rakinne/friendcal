import Foundation

/// Dual-purpose availability with SoftHold lifecycle.
/// Tap free in a Proposal → writes SoftHold to global profile + proposal-specific slot.
/// Prevents 10am double-book without over-blocking explorers who tap multiple dates.
/// Resolves eng-review P0/P1: expiry + promotion on lock + cleanup.
public final class AvailabilityService {

    public init() {}

    public enum TapResult {
        case softHold(AvailabilitySlot)
        case alreadyHeld // second friend's request sees pre-commit hold
    }

    /// Tap a free slot for a proposal. Creates SoftHold visible as "leaning" to others.
    /// - Parameters:
    ///   - existingSlots: current slots for this user (for collision check; caller provides DB rows)
    ///   - userID, range, proposalID, expiresAt: new hold
    ///   - now: the clock expiry is judged against (C2), so tests pin it like HeatmapBuilder's.
    /// Collision: if existing Hard Busy overlaps range → alreadyHeld; same for unexpired SoftHold from other proposal.
    /// A UX guard, not an invariant (A2): the server has no exclusion for softHolds.
    public func tapFreeSlot(userID: UUID, range: DateRange, proposalID: UUID, expiresAt: Date?, existingSlots: [AvailabilitySlot] = [], now: Date = .now) -> TapResult {
        let alive = expireStaleHolds(slots: existingSlots, now: now)
        for slot in alive where slot.range.overlaps(range) {
            if slot.state == .busy { return .alreadyHeld }
            if slot.state == .softHold && slot.sourceProposalID != proposalID { return .alreadyHeld }
        }
        return .softHold(AvailabilitySlot(userID: userID, range: range, sourceProposalID: proposalID, state: .softHold, expiresAt: expiresAt))
    }

    /// Settles a lock (D3, D12). Each recipient whose eligible holds, merged the way the heatmap
    /// merges them, cover the whole common `window` gets one Hard Busy block for exactly that window,
    /// so quorum and promotion agree and nobody is blocked beyond the plan. Eligibility uses the same
    /// injected `now` as HeatmapBuilder. Every SoftHold of this proposal is then cleared: promoted
    /// ones are replaced by their BusyBlock, the rest are released. Coverage is judged at whole-minute
    /// granularity (issue #5 D18): the lock window is minute-snapped, so a hold whose bound carries
    /// sub-second noise still covers the window that starts on its minute.
    /// Returns (promoted BusyBlocks, cleared slot IDs) so the caller can write both in one transaction.
    public func promoteToBusy(window: DateRange, proposalID: UUID, recipientIDs: [UUID], slots: [AvailabilitySlot], now: Date) -> (promoted: [BusyBlock], expiredIDs: [UUID]) {
        let ordered = HeatmapBuilder.distinct(recipientIDs)
        let recipients = Set(ordered)
        let eligible = slots.filter { HeatmapBuilder.isEligible($0, proposalID: proposalID, recipients: recipients, now: now) }
        let promoted: [BusyBlock] = ordered.compactMap { user in
            let coverage = HeatmapBuilder.merge(eligible.filter { $0.userID == user }.map(\.range))
            guard coverage.contains(where: { ProposalService.floorToMinute($0.lowerBound) <= window.lowerBound && window.upperBound <= ProposalService.ceilToMinute($0.upperBound) }) else { return nil }
            return BusyBlock(userID: user, range: window, visibility: .public, hiddenFrom: [], createdAt: now)
        }
        let cleared = slots.filter { $0.sourceProposalID == proposalID && $0.state == .softHold }.map(\.id)
        return (promoted, cleared)
    }

    public func expireStaleHolds(slots: [AvailabilitySlot], now: Date = .now) -> [AvailabilitySlot] {
        slots.filter { !$0.isExpired(at: now) }
    }

    /// DB reaper helper: call on launch + via Supabase cron Edge Function every hour
    static func reaperSQL() -> String {
        "delete from availability_slots where state = 'softHold' and expires_at < now();"
    }
}
