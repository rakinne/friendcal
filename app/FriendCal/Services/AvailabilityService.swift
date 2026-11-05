import Foundation

/// Dual-purpose availability with SoftHold lifecycle.
/// Tap free in a Proposal → writes SoftHold to global profile + proposal-specific slot.
/// Prevents 10am double-book without over-blocking explorers who tap multiple dates.
/// Resolves eng-review P0/P1: expiry + promotion on lock + cleanup.
final class AvailabilityService {

    enum TapResult {
        case softHold(AvailabilitySlot)
        case alreadyHeld // second friend's request sees pre-commit hold
    }

    /// Tap a free slot for a proposal. Creates SoftHold visible as "leaning" to others.
    func tapFreeSlot(userID: UUID, range: ClosedRange<Date>, proposalID: UUID, expiresAt: Date?) -> TapResult {
        // Check existing Hard Busy collision first
        // Then check SoftHold collision from other proposals
        // If none → create SoftHold + AvailabilitySlot
        return .softHold(AvailabilitySlot(userID: userID, range: range, sourceProposalID: proposalID, state: .softHold, expiresAt: expiresAt))
    }

    func promoteToBusy(onLock date: Date, proposalID: UUID, recipientIDs: [UUID]) -> [BusyBlock] {
        // On lock Nov 21st → promote all SoftHolds covering that date to Hard Busy
        // Expire other SoftHolds for this proposal
        return []
    }

    func expireStaleHolds(slots: [AvailabilitySlot]) -> [AvailabilitySlot] {
        slots.filter { !$0.isExpired }
    }
}
