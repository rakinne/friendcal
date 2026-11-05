import Foundation

enum BusyVisibility: String, Codable {
    case `public`
    case stealth // hiddenFrom contains excluded user IDs (e.g. Jalen)
}

struct BusyBlock: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var userID: UUID
    var range: ClosedRange<Date>
    var visibility: BusyVisibility = .public
    var hiddenFrom: [UUID] = [] // empty = public; non-empty = stealth — must be enforced server-side (RLS)
    var createdAt: Date = Date()

    // Server-side derived: what excluded viewer is allowed to see
    // NEVER include title/location/attendees — see StealthService
}

struct Event: Identifiable, Codable {
    var id: UUID
    var title: String
    var date: Date
    var venue: String?
    var hostID: UUID
    var attendeeIDs: [UUID]
    var busyBlockIDs: [UUID] // backing holds (stealth-aware)
    var potluckItems: [String] = []
    var playlistURL: URL?
    // Hype art template reference — Partiful-inspired
    var inviteArtTemplate: String = "partiful-classic"
}
