import Foundation
import Supabase

/// Supabase backend contract for FriendCal — Phase 1: Supabase chosen (D1 Option A).
/// Server enforces stealth via Postgres RLS on busy_blocks.hidden_from.
/// Client reads via sanitized_busy_blocks view for excluded viewers.

protocol SupabaseServiceProtocol {
    func fetchProposals(for userID: UUID) async throws -> [Proposal]
    func createProposal(_ p: Proposal) async throws
    func lockProposal(_ id: UUID, to date: Date) async throws
    func fetchBusyBlocks(for viewerID: UUID, in range: ClosedRange<Date>) async throws -> [BusyBlock]
    func subscribeRealtime(onProposal id: UUID, handler: @escaping ([AvailabilitySlot]) -> Void) -> Any
}

final class SupabaseService: SupabaseServiceProtocol {
    let client: SupabaseClient
    let supabaseURL: URL
    let anonKey: String

    init(url: URL, anonKey: String) {
        self.supabaseURL = url
        self.anonKey = anonKey
        self.client = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }

    /// Convenience: load from Secrets.plist (gitignored). Fails in previews if missing -> returns Mock behavior.
    static func fromSecrets() -> SupabaseService? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let urlStr = plist["SupabaseURL"], let url = URL(string: urlStr),
              let key = plist["SupabaseAnonKey"] else { return nil }
        return SupabaseService(url: url, anonKey: key)
    }

    func fetchProposals(for userID: UUID) async throws -> [Proposal] {
        try await client.from("proposals").select().eq("created_by", value: userID.uuidString).execute().value as [Proposal]
    }

    func createProposal(_ p: Proposal) async throws {
        try await client.from("proposals").insert(p).execute()
    }

    func lockProposal(_ id: UUID, to date: Date) async throws {
        try await client.from("proposals").update(["locked_date": ISO8601DateFormatter().string(from: date), "status": "locked"]).eq("id", value: id.uuidString).execute()
    }

    func fetchBusyBlocks(for viewerID: UUID, in range: ClosedRange<Date>) async throws -> [BusyBlock] {
        // Server-side RLS + sanitized view ensures excluded viewers (e.g. Jalen) never get event payload
        // We query sanitized_busy_blocks for safety; PostgREST will apply RLS hidden_from check
        let iso = ISO8601DateFormatter()
        return try await client.from("sanitized_busy_blocks").select()
            .gte("range", value: iso.string(from: range.lowerBound))
            .lte("range", value: iso.string(from: range.upperBound))
            .execute().value as [BusyBlock]
    }

    func subscribeRealtime(onProposal id: UUID, handler: @escaping ([AvailabilitySlot]) -> Void) -> Any {
        // Supabase Realtime channel for heatmap live convergence
        let channel = client.channel("proposal-\(id.uuidString)")
        Task {
            let stream = channel.postgresChange(event: .all, schema: "public", table: "availability_slots", filter: "source_proposal_id=eq.\(id.uuidString)")
            for await _ in stream {
                // Refetch slots and call handler — debounce in ViewModel
                if let slots: [AvailabilitySlot] = try? await client.from("availability_slots").select().eq("source_proposal_id", value: id.uuidString).execute().value {
                    handler(slots)
                }
            }
        }
        Task { await channel.subscribe() }
        return channel
    }
}

/// Mock for previews / SwiftUI + StealthTests — never leaks hiddenFrom payload.
final class MockSupabaseService: SupabaseServiceProtocol {
    var proposals: [Proposal] = []
    var busyBlocks: [BusyBlock] = []
    func fetchProposals(for userID: UUID) async throws -> [Proposal] { proposals }
    func createProposal(_ p: Proposal) async throws { proposals.append(p) }
    func lockProposal(_ id: UUID, to date: Date) async throws { }
    func fetchBusyBlocks(for viewerID: UUID, in range: ClosedRange<Date>) async throws -> [BusyBlock] {
        busyBlocks.filter { $0.range.overlaps(range) }.map { block in
            if block.hiddenFrom.contains(viewerID) {
                return BusyBlock(id: block.id, userID: block.userID, range: block.range, visibility: .public, hiddenFrom: [], createdAt: block.createdAt)
            }
            return block
        }
    }
    func subscribeRealtime(onProposal id: UUID, handler: @escaping ([AvailabilitySlot]) -> Void) -> Any { NSObject() }
}
