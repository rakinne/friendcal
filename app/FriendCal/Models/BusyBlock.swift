import Foundation

public enum BusyVisibility: String, Codable {
    case `public`
    case stealth // hiddenFrom contains excluded user IDs (e.g. Jalen)
}

public struct BusyBlock: Identifiable, Codable, Equatable {
    public var id: UUID
    public var userID: UUID
    public var range: DateRange
    public var visibility: BusyVisibility
    public var hiddenFrom: [UUID] // empty = public; non-empty = stealth — must be enforced server-side (RLS)
    public var createdAt: Date

    public init(id: UUID = UUID(), userID: UUID, range: DateRange, visibility: BusyVisibility = .public, hiddenFrom: [UUID] = [], createdAt: Date = Date()) {
        self.id = id
        self.userID = userID
        self.range = range
        self.visibility = visibility
        self.hiddenFrom = hiddenFrom
        self.createdAt = createdAt
    }

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
