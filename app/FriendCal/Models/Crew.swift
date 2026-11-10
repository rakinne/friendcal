import Foundation

/// A person on Groups: you or a friend you are connected to.
public struct Buddy: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var isOnline: Bool

    public init(id: UUID, name: String, isOnline: Bool = true) {
        self.id = id
        self.name = name
        self.isOnline = isOnline
    }
}

/// A crew: a named set of friends. You are in every crew you can see, so `memberIDs` lists friends
/// only. Crews are optional; a friend can belong to more than one.
public struct Crew: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var memberIDs: [UUID]

    public init(id: UUID = UUID(), name: String, memberIDs: [UUID]) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
    }
}

/// One folder on Groups: a crew, or the automatic "Friends on FriendCal" folder that holds everyone
/// you are connected to who is not in a crew yet. That folder is why the screen is never empty for
/// someone with no crew, and why a friend who joins through your link has somewhere to land.
public struct GroupsFolder: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case crew(UUID)
        case friends
    }

    public var kind: Kind
    public var title: String
    public var members: [Buddy]

    public var id: String {
        switch kind {
        case .crew(let id): "crew.\(id.uuidString)"
        case .friends: "friends"
        }
    }

    public var isAutomatic: Bool { kind == .friends }

    public static let friendsTitle = "Friends on FriendCal"

    /// "(4/5 online)" for the folder header: friends only, you excluded.
    public var onlineCount: Int { members.filter(\.isOnline).count }
}

public enum GroupsLayout {
    /// Crews in the order given, then the automatic folder. Members keep their stored order, so rows
    /// never jump when a status changes. A member id with no matching friend (a friend who left) is
    /// dropped. The automatic folder shows when it has someone, or when there are no crews at all
    /// (it then hosts the invite card).
    public static func folders(crews: [Crew], friends: [Buddy]) -> [GroupsFolder] {
        let byID = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0) })
        var inACrew = Set<UUID>()
        var result: [GroupsFolder] = crews.map { crew in
            let members = crew.memberIDs.compactMap { byID[$0] }
            inACrew.formUnion(members.map(\.id))
            return GroupsFolder(kind: .crew(crew.id), title: crew.name, members: members)
        }
        let loose = friends.filter { !inACrew.contains($0.id) }
        if !loose.isEmpty || crews.isEmpty {
            result.append(GroupsFolder(kind: .friends, title: GroupsFolder.friendsTitle, members: loose))
        }
        return result
    }
}

/// The "Start a crew" form: who is ticked and what it is called.
public struct CrewDraft: Equatable, Sendable {
    public static let maxNameLength = 30

    public var name = ""
    public private(set) var selected: [UUID] = []

    public init() {}

    public mutating func toggle(_ id: UUID) {
        if let i = selected.firstIndex(of: id) { selected.remove(at: i) } else { selected.append(id) }
    }

    public func isSelected(_ id: UUID) -> Bool { selected.contains(id) }

    /// A crew needs at least one friend besides you.
    public var canCreate: Bool { !selected.isEmpty }

    /// What the name field's placeholder shows: the first names of whoever is ticked.
    public func suggestedName(among friends: [Buddy]) -> String {
        let names = selected.compactMap { id in friends.first { $0.id == id }?.name }
        switch names.count {
        case 0: return "My crew"
        case 1: return "You & \(names[0])"
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) & \(names.count - 2) more"
        }
    }

    /// The typed name, else the suggestion. Capped at `maxNameLength`.
    public func resolvedName(among friends: [Buddy]) -> String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = typed.isEmpty ? suggestedName(among: friends) : typed
        return String(chosen.prefix(Self.maxNameLength))
    }
}
