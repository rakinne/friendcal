import Foundation

/// The token in a friend link: exactly 22 characters of `[A-Za-z0-9_-]` (base64url of one UUID, see
/// supabase/friends.sql). One definition, so `DeepLink`, the stores and the sheet cannot disagree.
public enum FriendToken {
    public static let length = 22

    public static func isValid(_ text: String) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F: return true   // 0-9 A-Z a-z - _
            default: return false
            }
        }
    }

    /// `friendcal.app/f/<token>`: how the link reads on screen, with no scheme and no name hint.
    public static func display(_ token: String) -> String { "\(DeepLink.webHost)/\(DeepLink.friendWebPath)/\(token)" }
}

/// Someone you are connected to, or are about to be: what `my_friends()` and the link answers carry.
public struct Friend: Identifiable, Equatable, Hashable, Sendable {
    /// What a person whose Apple ID withheld a name appears as until they set one in Me.
    public static let placeholderName = "Friend"

    public let id: UUID
    public var name: String
    public var avatarURL: URL?
    /// When the friendship began. nil for fixture friends and for the inviter on a link answer.
    public var connectedAt: Date?

    public init(id: UUID, name: String, avatarURL: URL? = nil, connectedAt: Date? = nil) {
        self.id = id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? Self.placeholderName : trimmed
        self.avatarURL = avatarURL
        self.connectedAt = connectedAt
    }
}

/// What opening a friend link would do for this caller (`preview_friend_link`, `accept_friend_link`).
/// `dead` carries no one and no reason, so a probe learns nothing about which cause it was.
public struct FriendLinkAnswer: Equatable, Sendable {
    public enum Status: String, Sendable { case valid, own, already, dead }

    public var status: Status
    /// The inviter, for `valid` and `already` only. This is the name the Accept screen shows, never
    /// the hint in the URL.
    public var person: Friend?

    public init(status: Status, person: Friend? = nil) {
        self.status = status
        self.person = person
    }

    public static let dead = FriendLinkAnswer(status: .dead)
    public static let own = FriendLinkAnswer(status: .own)
}

/// The friend roster and the rules around it, in the fast test lane. `GroupsSession` holds one and
/// only moves state; every decision about what is stale, what is new and what the wheel draws is here.
///
/// STALE REFRESHES. Each refresh takes the current generation when it starts; a local accept or
/// remove bumps it. A refresh that comes back under an older number is discarded, so a slow read
/// that began before a Connect cannot erase the friend that Connect just made.
///
/// WHAT IS NEW. `knownIDs` is the per-account saved set of friends already seen. It is nil until the
/// first roster load for that account, and that load fills it silently: "never loaded" is not
/// "loaded and empty", so a new person's first friend IS announced while an existing person's
/// reinstall is not. A friend not in the set is an arrival, and stays one (across launches too) until
/// `takeArrivals()` is called, which is done when Groups is on screen. An id that leaves the roster
/// leaves the set.
public struct FriendRoster: Equatable, Sendable {
    public private(set) var friends: [Friend]
    public private(set) var hasLoaded: Bool
    public private(set) var generation = 0
    public private(set) var knownIDs: Set<UUID>?

    public init(friends: [Friend] = [], knownIDs: Set<UUID>? = nil, hasLoaded: Bool = false) {
        self.friends = friends
        self.knownIDs = knownIDs
        self.hasLoaded = hasLoaded
    }

    /// Starts a refresh. Pass the result back to `apply`.
    public func beginRefresh() -> Int { generation }

    /// A local accept or remove: refreshes that began earlier are now stale.
    public mutating func noteLocalChange() { generation += 1 }

    /// Applies a loaded roster. False means it was discarded as stale. Friends already shown keep
    /// their place, so rows never jump; people who are new come first, newest first.
    @discardableResult
    public mutating func apply(_ loaded: [Friend], startedAt: Int) -> Bool {
        guard startedAt == generation else { return false }
        let loadedIDs = Set(loaded.map(\.id))
        let byID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = friends.compactMap { byID[$0.id] }
        let keptIDs = Set(kept.map(\.id))
        friends = loaded.filter { !keptIDs.contains($0.id) } + kept
        knownIDs = knownIDs.map { $0.intersection(loadedIDs) } ?? loadedIDs
        hasLoaded = true
        return true
    }

    /// The recipient tapped Connect: the inviter is not an "arrival" for the person who just made them.
    public mutating func markKnown(_ id: UUID) {
        knownIDs = (knownIDs ?? []).union([id])
    }

    /// Shows a friend at once, after a local accept, without waiting for the next read.
    public mutating func insertLocally(_ friend: Friend) {
        noteLocalChange()
        markKnown(friend.id)
        friends.removeAll { $0.id == friend.id }
        friends.insert(friend, at: 0)
    }

    public mutating func removeLocally(_ id: UUID) {
        noteLocalChange()
        friends.removeAll { $0.id == id }
        knownIDs?.remove(id)
    }

    /// Friends who arrived (they accepted your link) and have not been announced yet.
    public var arrivals: [Friend] {
        guard let known = knownIDs else { return [] }
        return friends.filter { !known.contains($0.id) }
    }

    /// Announces the arrivals: returns them and adds them to the saved set.
    @discardableResult
    public mutating func takeArrivals() -> [Friend] {
        let taken = arrivals
        if !taken.isEmpty { knownIDs = (knownIDs ?? []).union(taken.map(\.id)) }
        return taken
    }

    /// The Moments line for new arrivals: "You and Jess are connected"; several at once read
    /// "Jess and 2 others are connected".
    public static func arrivalText(_ arrivals: [Friend]) -> String? {
        switch arrivals.count {
        case 0: return nil
        case 1: return "You and \(arrivals[0].name) are connected"
        default:
            let others = arrivals.count - 1
            return "\(arrivals[0].name) and \(others) \(others == 1 ? "other" : "others") are connected"
        }
    }

    // MARK: The wheel

    public enum WheelSource: Equatable, Sendable { case planMembers, friends }

    /// The wheel draws the current plan's members; with none it draws the caller's friends, so the
    /// "Add your first fave" state goes away after the first friend.
    public static func wheelSource(planMemberCount: Int) -> WheelSource { planMemberCount > 0 ? .planMembers : .friends }

    /// Faces for up to `cap` people; past the cap, `cap - 1` faces and a "+N" for the rest. `pinned`
    /// (the active friend) always keeps a face. Same rule for plan members and friends.
    public static func wheelFaces<T: Identifiable>(_ all: [T], cap: Int = 10, pinned: T.ID? = nil) -> (faces: [T], overflow: Int) {
        guard all.count > cap else { return (all, 0) }
        var faces = Array(all.prefix(cap - 1))
        if let pinned, let active = all.first(where: { $0.id == pinned }), !faces.contains(where: { $0.id == pinned }) {
            faces[cap - 2] = active
        }
        return (faces, all.count - (cap - 1))
    }
}
