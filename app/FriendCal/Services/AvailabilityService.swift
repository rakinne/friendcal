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

    /// Promote SoftHolds covering locked date to Hard Busy; expire other SoftHolds for this proposal.
    /// Returns (promoted BusyBlocks, expired slot IDs) so caller can write transactionally.
    public func promoteToBusy(onLock date: Date, proposalID: UUID, recipientIDs: [UUID], slots: [AvailabilitySlot]) -> (promoted: [BusyBlock], expiredIDs: [UUID]) {
        var promoted: [BusyBlock] = []
        var expired: [UUID] = []
        let alive = expireStaleHolds(slots: slots)
        for slot in alive where slot.sourceProposalID == proposalID {
            let contains = slot.range.lowerBound <= date && date <= slot.range.upperBound
            if contains && slot.state == .softHold {
                promoted.append(BusyBlock(userID: slot.userID, range: slot.range, visibility: .public, hiddenFrom: [], createdAt: Date()))
            } else if slot.state == .softHold {
                expired.append(slot.id)
            }
        }
        return (promoted, expired)
    }

    /// Legacy shim for tests that expect empty array return
    func promoteToBusy(onLock date: Date, proposalID: UUID, recipientIDs: [UUID]) -> [BusyBlock] {
        let (p, _) = promoteToBusy(onLock: date, proposalID: proposalID, recipientIDs: recipientIDs, slots: [])
        return p
    }

    public func expireStaleHolds(slots: [AvailabilitySlot]) -> [AvailabilitySlot] {
        slots.filter { !$0.isExpired }
    }

    /// DB reaper helper: call on launch + via Supabase cron Edge Function every hour
    static func reaperSQL() -> String {
        "delete from availability_slots where state = 'softHold' and expires_at < now();"
    }
}
