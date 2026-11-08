import Foundation

public struct User: Identifiable, Codable, Equatable {
    /// What delete_account() leaves in display_name (supabase/users_auth.sql): the tombstone's name.
    public static let deletedDisplayName = "Deleted account"
    public var isDeleted: Bool { displayName == Self.deletedDisplayName }

    public var id: UUID
    public var displayName: String
    public var avatarURL: URL?
    public var circles: [UUID] // Circle IDs
    /// Global availability derived from AvailabilitySlot taps — FriendCal IS the calendar
    public var globalAvailability: [AvailabilitySlot]

    public init(id: UUID, displayName: String, avatarURL: URL? = nil, circles: [UUID] = [], globalAvailability: [AvailabilitySlot] = []) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.circles = circles
        self.globalAvailability = globalAvailability
    }
}

struct Circle: Identifiable, Codable {
    var id: UUID
    var name: String // e.g. "Friendsgivemas crew", "Park crew"
    var memberIDs: [UUID]
}
