import Foundation
import Supabase

/// Supabase backend contract for FriendCal — Phase 1: Supabase chosen (D1 Option A).
/// Server enforces stealth via Postgres RLS on busy_blocks.hidden_from.
/// Client reads via sanitized_busy_blocks view for excluded viewers.

protocol SupabaseServiceProtocol {
    func fetchProposals(for userID: UUID) async throws -> [Proposal]
    func createProposal(_ p: Proposal) async throws
    func lockProposal(_ id: UUID, to date: Date) async throws
    func fetchBusyBlocks(for viewerID: UUID, in range: DateRange) async throws -> [BusyBlock]
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

    func fetchBusyBlocks(for viewerID: UUID, in range: DateRange) async throws -> [BusyBlock] {
        // gstack-shortcut(R1): strict — query sanitized view (no hidden_from/event payload) and map to BusyBlock with hidden strippped
        // View returns range_start/range_end (tstzrange split) + id/user_id/created_at; decode as SanitizedBusy then rehydrate
        struct SanitizedRow: Decodable {
            var id: UUID; var user_id: UUID; var range_start: Date; var range_end: Date; var created_at: Date
        }
        let rows: [SanitizedRow] = try await client.from("sanitized_busy_blocks").select()
            .execute().value as [SanitizedRow]
        return rows.filter { $0.range_start <= range.upperBound && $0.range_end >= range.lowerBound }.map { r in
            BusyBlock(id: r.id, userID: r.user_id, range: DateRange(lower: r.range_start, upper: r.range_end), visibility: .public, hiddenFrom: [], createdAt: r.created_at)
        }
    }

    func subscribeRealtime(onProposal id: UUID, handler: @escaping ([AvailabilitySlot]) -> Void) -> Any {
        // TODO: Wire Supabase Realtime (schema in supabase/schema.sql, see TODOS P0). Stubbed to keep Phase 1 building.
        // Real impl: channel.onPostgresChange + subscribeWithError once supabase-swift API stabilized.
        let channel = client.channel("proposal-\(id.uuidString)")
        Task { _ = try? await channel.subscribeWithError() }
        return channel
    }
}

/// Mock for previews / SwiftUI + StealthTests — never leaks hiddenFrom payload.
public final class MockSupabaseService: SupabaseServiceProtocol {
    public init() {}
    var proposals: [Proposal] = []
    var busyBlocks: [BusyBlock] = []
    func fetchProposals(for userID: UUID) async throws -> [Proposal] { proposals }
    func createProposal(_ p: Proposal) async throws { proposals.append(p) }
    func lockProposal(_ id: UUID, to date: Date) async throws { }
    func fetchBusyBlocks(for viewerID: UUID, in range: DateRange) async throws -> [BusyBlock] {
        busyBlocks.filter { $0.range.overlaps(range) }.map { block in
            if block.hiddenFrom.contains(viewerID) {
                return BusyBlock(id: block.id, userID: block.userID, range: block.range, visibility: .public, hiddenFrom: [], createdAt: block.createdAt)
            }
            return block
        }
    }
    func subscribeRealtime(onProposal id: UUID, handler: @escaping ([AvailabilitySlot]) -> Void) -> Any { NSObject() }
}
