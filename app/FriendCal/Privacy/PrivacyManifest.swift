import Foundation

/// Documents privacy invariants for manual QA with surprise-brunch scenario (Mica→Jalen Nov 7).
/// Blind test criterion: excluded user (Jalen) cannot distinguish surprise from generic Busy after 3 coordinated blocks.
/// Rules:
/// 1. hiddenFrom enforced server-side via RLS (never client filter)
/// 2. Push payloads sanitized (no title in notification body for excluded)
/// 3. BusyBlockView styling identical for all visibilities
/// 4. Correlation noise: stagger write timestamps + per-viewer jitter (future)
/// 5. Manual Busy holds required as cover traffic — encourage 2-3 per user on onboarding

enum PrivacyInvariant {
    static let stealthRequiresManualCover = true
    static let serverSideEnforcement = true
    static let identicalBusyStyling = true
}
