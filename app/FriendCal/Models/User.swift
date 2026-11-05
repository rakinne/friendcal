import Foundation

struct User: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var displayName: String
    var avatarURL: URL?
    var circles: [UUID] = [] // Circle IDs
    /// Global availability derived from AvailabilitySlot taps — FriendCal IS the calendar
    var globalAvailability: [AvailabilitySlot] = []
}

struct Circle: Identifiable, Codable {
    var id: UUID
    var name: String // e.g. "Friendsgivemas crew", "Park crew"
    var memberIDs: [UUID]
}
