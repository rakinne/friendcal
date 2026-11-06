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
    /// Collision: if existing Hard Busy overlaps range → alreadyHeld; same for unexpired SoftHold from other proposal.
    public func tapFreeSlot(userID: UUID, range: DateRange, proposalID: UUID, expiresAt: Date?, existingSlots: [AvailabilitySlot] = []) -> TapResult {
        let alive = expireStaleHolds(slots: existingSlots)
        for slot in alive where slot.range.overlaps(range) {
            if slot.state == .busy { return .alreadyHeld }
            if slot.state == .softHold && slot.sourceProposalID != proposalID { return .alreadyHeld }
        }
        return .softHold(AvailabilitySlot(userID: userID, range: range, sourceProposalID: proposalID, state: .softHold, expiresAt: expiresAt))
    }

    /// On lock, promote this proposal's recipient SoftHolds that cover the whole locked common
    /// window (D3, D12) to Hard Busy; expire every other SoftHold for this proposal.
    /// Returns (promoted BusyBlocks, expired slot IDs) so caller can write transactionally.
    public func promoteToBusy(window: DateRange, proposalID: UUID, recipientIDs: [UUID], slots: [AvailabilitySlot]) -> (promoted: [BusyBlock], expiredIDs: [UUID]) {
        var promoted: [BusyBlock] = []
        var expired: [UUID] = []
        let recipients = Set(recipientIDs)
        let alive = expireStaleHolds(slots: slots)
        for slot in alive where slot.sourceProposalID == proposalID && slot.state == .softHold {
            let covers = slot.range.lowerBound <= window.lowerBound && window.upperBound <= slot.range.upperBound
            if covers && recipients.contains(slot.userID) {
                promoted.append(BusyBlock(userID: slot.userID, range: slot.range, visibility: .public, hiddenFrom: [], createdAt: Date()))
            } else {
                expired.append(slot.id)
            }
        }
        return (promoted, expired)
    }

    public func expireStaleHolds(slots: [AvailabilitySlot]) -> [AvailabilitySlot] {
        slots.filter { !$0.isExpired }
    }

    /// DB reaper helper: call on launch + via Supabase cron Edge Function every hour
    static func reaperSQL() -> String {
        "delete from availability_slots where state = 'softHold' and expires_at < now();"
    }
}
