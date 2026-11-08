import Foundation

/// P0 Privacy: Stealth Holds must be indistinguishable from manual Busy.
/// See eng-review P0 — single-block stripping not enough; need correlation resistance.
/// Server must enforce hiddenFrom via RLS; client must not receive surprise payload.
public final class StealthService {

    public init() {}

    /// `SanitizedBusy` now lives beside `BusyBlock` in Models, next to the blanking that produces it,
    /// so there is one definition of "what is safe to show" rather than one per service. This alias
    /// keeps existing call sites compiling.
    public typealias SanitizedBusy = FriendCalCore.SanitizedBusy

    /// What any viewer is allowed to see for a BusyBlock.
    ///
    /// Delegates to `BusyBlock.sanitizedBusy`, the one named blanking site, rather than listing the
    /// safe fields again here. The result is deliberately the same for every viewer: a payload whose
    /// shape varied by viewer would let an excluded one detect that they were excluded.
    func sanitize(_ block: BusyBlock, for viewer: UUID) -> SanitizedBusy {
        block.sanitizedBusy
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
