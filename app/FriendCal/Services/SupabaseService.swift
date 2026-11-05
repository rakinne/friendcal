import Foundation

/// Supabase backend contract for FriendCal — Phase 1: Supabase chosen (D1 Option A).
/// This is the app-side interface; actual Supabase Swift SDK wiring is injected via protocol
/// so previews/tests don't need live creds. Server enforces stealth via Postgres RLS.
///
/// Tables (proposed):
/// - users(id uuid pk, display_name text, avatar_url text)
/// - proposals(id uuid pk, title text, window_start timestamptz, window_end timestamptz, created_by uuid, distribution jsonb, status text, locked_date timestamptz)
/// - availability_slots(id uuid pk, user_id uuid, range tstzrange, source_proposal_id uuid, state text, expires_at timestamptz)
/// - busy_blocks(id uuid pk, user_id uuid, range tstzrange, visibility text, hidden_from uuid[], created_at timestamptz, event_id uuid)
/// - events(id uuid pk, title text, date timestamptz, venue text, host_id uuid, attendee_ids uuid[], busy_block_ids uuid[], invite_art_template text)
///
/// RLS invariant (P0): surprise-brunch (Mica→Jalen Nov 7, Mardi Gras Tuesday) must never leak to Jalen.
/// Policy on busy_blocks: excluded viewers get only sanitized row (id, user_id, range) via view; same for events.
/// See docs/supabase-rls.sql for SQL.
protocol SupabaseServiceProtocol {
    func fetchProposals(for userID: UUID) async throws -> [Proposal]
    func createProposal(_ p: Proposal) async throws
    func lockProposal(_ id: UUID, to date: Date) async throws
    func fetchBusyBlocks(for viewerID: UUID, in range: ClosedRange<Date>) async throws -> [BusyBlock] // server-sanitized
    func subscribeRealtime(onProposal id: UUID, handler: @escaping ([AvailabilitySlot]) -> Void) -> Any
}

final class SupabaseService: SupabaseServiceProtocol {
    let supabaseURL: URL
    let anonKey: String

    init(url: URL, anonKey: String) {
        self.supabaseURL = url
        self.anonKey = anonKey
    }

    func fetchProposals(for userID: UUID) async throws -> [Proposal] { [] }
    func createProposal(_ p: Proposal) async throws { }
    func lockProposal(_ id: UUID, to date: Date) async throws { }
    func fetchBusyBlocks(for viewerID: UUID, in range: ClosedRange<Date>) async throws -> [BusyBlock] { [] }
    func subscribeRealtime(onProposal id: UUID, handler: @escaping ([AvailabilitySlot]) -> Void) -> Any { NSObject() }
}

/// Mock for previews / SwiftUI + StealthTests — never leaks hiddenFrom payload.
final class MockSupabaseService: SupabaseServiceProtocol {
    var proposals: [Proposal] = []
    var busyBlocks: [BusyBlock] = []
    func fetchProposals(for userID: UUID) async throws -> [Proposal] { proposals }
    func createProposal(_ p: Proposal) async throws { proposals.append(p) }
    func lockProposal(_ id: UUID, to date: Date) async throws { }
    func fetchBusyBlocks(for viewerID: UUID, in range: ClosedRange<Date>) async throws -> [BusyBlock] {
        // Simulate server-side RLS: strip hiddenFrom viewer's blocks to SanitizedBusy semantics (range only)
        busyBlocks.filter { $0.range.overlaps(range) }.map { block in
            if block.hiddenFrom.contains(viewerID) {
                // Return with visibility scrubbed — client never sees title/venue (stored separately in events table, also RLS'd)
                return BusyBlock(id: block.id, userID: block.userID, range: block.range, visibility: .public, hiddenFrom: [], createdAt: block.createdAt)
            }
            return block
        }
    }
    func subscribeRealtime(onProposal id: UUID, handler: @escaping ([AvailabilitySlot]) -> Void) -> Any { NSObject() }
}
