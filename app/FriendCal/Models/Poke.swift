import Foundation

struct Poke: Identifiable, Codable {
    var id: UUID = UUID()
    var from: UUID
    var to: UUID
    var proposalID: UUID
    var createdAt: Date = Date()
    // Rate limit: max 1 per (from,to,proposal) per 24h; mute per user
}
