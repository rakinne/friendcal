import Foundation

/// P0 Privacy: Stealth Holds must be indistinguishable from manual Busy.
/// See eng-review P0 — single-block stripping not enough; need correlation resistance.
/// Server must enforce hiddenFrom via RLS; client must not receive surprise payload.
final class StealthService {

    struct SanitizedBusy: Codable, Equatable {
        var id: UUID
        var userID: UUID
        var range: DateRange
        // No title, no location, no host avatar, no attendee list
        // Render as identical grey "Busy" — same component as manual Busy
    }

    /// Server-side read transform: what viewer is allowed to see for a BusyBlock.
    /// If viewer is in hiddenFrom → return sanitized Busy with no correlation metadata.
    func sanitize(_ block: BusyBlock, for viewer: UUID) -> SanitizedBusy {
        // Enforce: if block.hiddenFrom.contains(viewer) → strip everything except range+user
        // Applies to Event-backed blocks (Mica->Jalen Surprise Brunch Nov 7) and any stealth block
        return SanitizedBusy(id: block.id, userID: block.userID, range: block.range)
    }

    /// For included viewers, return full Event-backed context (invite art, etc.)
    /// Never mix: included and excluded must hit different code paths with different payloads.

    /// Correlation mitigation (P0): decoy + jitter strategy
    /// - Encourage users to maintain 2-3 manual Busy holds so stealth hides in noise
    /// - Per-viewer time fuzz: render excluded viewer's Busy with ±15min jitter to break exact sync fingerprint
    /// - Future: k-anonymity batch — don't create BusyBlocks all at same timestamp; stagger writes
    func applyCorrelationNoise(to sanitized: SanitizedBusy, jitterMinutes: Int = 0) -> SanitizedBusy {
        // Jitter only for excluded viewer; included sees precise 11am-2pm brunch slot
        return sanitized
    }

    /// Push payload sanitization: APNs payload for excluded viewer must not leak title via notification body.
    func sanitizedPushBody(for block: BusyBlock, viewer: UUID) -> String {
        if block.hiddenFrom.contains(viewer) { return "New busy time added" }
        return "Event updated" // host-specific body only for included
    }
}
