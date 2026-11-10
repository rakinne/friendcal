import Foundation

/// Someone who joined a plan after it locked (tag_alongs in supabase/social.sql). The plan's
/// attendee list says they are in; this says how they got in, and when.
public struct TagAlong: Identifiable, Equatable, Codable, Sendable {
    public var proposalID: UUID
    public var userID: UUID
    public var createdAt: Date

    public var id: String { "\(proposalID.uuidString).\(userID.uuidString)" }

    public init(proposalID: UUID, userID: UUID, createdAt: Date) {
        self.proposalID = proposalID
        self.userID = userID
        self.createdAt = createdAt
    }
}

/// When a plan can be tagged along to. The Swift mirror of the checks in tag_along(), in the same
/// order, so a screen never offers a button the server will refuse: the server is still the one
/// that decides, and the one check it alone can make (are you already busy then?) stays there.
public enum TagAlongRules {
    public enum Refusal: Equatable, Sendable {
        /// Hidden from the viewer, or no viewer. Indistinguishable from a plan that is not there.
        case notFound
        /// Still collecting times: mark yours instead.
        case notLocked
        /// Cancelled or still a draft.
        case closed
        case over
        case alreadyIn
    }

    public static func refusal(_ plan: Proposal, user: UUID?, now: Date) -> Refusal? {
        guard let user, !plan.hiddenFrom.contains(user) else { return .notFound }
        if plan.status == .requesting { return .notLocked }
        guard plan.status == .locked else { return .closed }
        guard let window = plan.lockedWindow, window.upperBound > now else { return .over }
        if plan.lockedAttendeeIDs.contains(user) { return .alreadyIn }
        return nil
    }

    public static func canTagAlong(_ plan: Proposal, user: UUID?, now: Date) -> Bool {
        refusal(plan, user: user, now: now) == nil
    }

    /// A friend's plans the viewer could join: the friend is going (or hosting), the viewer is not,
    /// and it has not ended. Soonest first; ties broken by id so the list never reshuffles.
    public static func candidates(_ plans: [Proposal], with friend: UUID, me: UUID?, now: Date) -> [Proposal] {
        plans
            .filter { ($0.lockedAttendeeIDs.contains(friend) || $0.createdBy == friend) && canTagAlong($0, user: me, now: now) }
            .sorted { a, b in
                let (x, y) = (a.lockedDate ?? .distantFuture, b.lockedDate ?? .distantFuture)
                return x != y ? x < y : a.id.uuidString < b.id.uuidString
            }
    }

    /// What the person who joined reads, on every screen that can join. The host is only "told"
    /// when the host is somebody else.
    public static func joinedText(planTitle: String, hostName: String?, isHost: Bool) -> String {
        isHost ? "You're in for \(planTitle)." : "You're in for \(planTitle). \(hostName ?? "The host") has been told."
    }

    /// "Leo + 3 are in", "Leo is in", "4 are in". Counts attendees; the friend is named when going.
    public static func whoIsIn(_ plan: Proposal, friend: (id: UUID, name: String)?) -> String {
        let count = plan.lockedAttendeeIDs.count
        guard let friend, plan.lockedAttendeeIDs.contains(friend.id) else {
            return count == 1 ? "1 is in" : "\(count) are in"
        }
        return count <= 1 ? "\(friend.name) is in" : "\(friend.name) + \(count - 1) are in"
    }
}

/// One line in the host's inbox: "Cleo is tagging along to Tacos."
public struct TagAlongNotice: Identifiable, Equatable, Sendable {
    public var proposalID: UUID
    public var userID: UUID
    public var planTitle: String
    public var createdAt: Date

    public var id: String { "\(proposalID.uuidString).\(userID.uuidString)" }

    public init(proposalID: UUID, userID: UUID, planTitle: String, createdAt: Date) {
        self.proposalID = proposalID
        self.userID = userID
        self.planTitle = planTitle
        self.createdAt = createdAt
    }
}

/// Everything the Pokes tab reads, in one fetch: the caller's pokes in both directions, the tag
/// alongs on plans they host, and the names needed to print them.
public struct SocialInbox: Equatable, Sendable {
    public var pokes: [Poke]
    public var tagAlongs: [TagAlongNotice]
    public var names: [UUID: String]
    /// Titles of the plans the pokes are about. Only plans the caller can read ever land here.
    public var planTitles: [UUID: String]

    public static let empty = SocialInbox(pokes: [], tagAlongs: [], names: [:], planTitles: [:])
    /// What a row shows when a name is not readable (a friend who left, a plan no longer shared).
    public static let unknownName = "A friend"

    public init(pokes: [Poke], tagAlongs: [TagAlongNotice], names: [UUID: String], planTitles: [UUID: String] = [:]) {
        self.pokes = pokes
        self.tagAlongs = tagAlongs
        self.names = names
        self.planTitles = planTitles
    }

    public func name(of id: UUID) -> String { names[id] ?? Self.unknownName }
}

/// The Pokes tab, sectioned. Built from the inbox and a clock, so the same inbox re-sorts itself
/// as pokes fade without another fetch.
public struct PokeFeed: Equatable, Sendable {
    /// How long a finished poke stays listed.
    public static let history: TimeInterval = 24 * 3600
    /// How long a tag along stays in the host's list.
    public static let noticeWindow: TimeInterval = 7 * 24 * 3600

    /// Live pokes to you. Newest first. Its count is the tab's badge.
    public var forYou: [Poke]
    /// People who joined your plans. Newest first.
    public var tagAlongs: [TagAlongNotice]
    /// Pokes you sent that are still out, or were answered within the hour. Newest first.
    public var sent: [Poke]
    /// Everything else from the last day, newest first.
    public var earlier: [Poke]

    public var isEmpty: Bool { forYou.isEmpty && tagAlongs.isEmpty && sent.isEmpty && earlier.isEmpty }

    public static func build(_ inbox: SocialInbox, me: UUID?, now: Date) -> PokeFeed {
        guard let me else { return PokeFeed(forYou: [], tagAlongs: [], sent: [], earlier: []) }
        let recent = inbox.pokes
            .filter { now.timeIntervalSince($0.createdAt) < history }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }

        var forYou: [Poke] = [], sent: [Poke] = [], earlier: [Poke] = []
        for poke in recent {
            let state = poke.state(at: now)
            if poke.toID == me {
                if case .live = state { forYou.append(poke) } else { earlier.append(poke) }
            } else if poke.fromID == me {
                switch state {
                case .live: sent.append(poke)
                case .acknowledged(let at, _) where now.timeIntervalSince(at) < Poke.lifetime: sent.append(poke)
                default: earlier.append(poke)
                }
            }
        }
        let notices = inbox.tagAlongs
            .filter { $0.userID != me && now.timeIntervalSince($0.createdAt) < noticeWindow }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
        return PokeFeed(forYou: forYou, tagAlongs: notices, sent: sent, earlier: earlier)
    }

    /// The live poke you have out to this friend, if any. What every Poke button reads to show
    /// "58 min left" instead of pretending a second poke would do something.
    public static func livePoke(in inbox: SocialInbox, from me: UUID?, to friend: UUID, now: Date) -> Poke? {
        guard let me else { return nil }
        return inbox.pokes
            .filter { $0.fromID == me && $0.toID == friend && $0.isLive(at: now) }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The one line at the top of the tab, in the spirit of Groups' Moments.
    public func headline(names: (UUID) -> String, now: Date) -> String {
        if let first = forYou.first {
            let left = PokeText.timeLine(first, now: now)
            return forYou.count == 1
                ? "\(names(first.fromID)) poked you. \(left)."
                : "\(names(first.fromID)) and \(forYou.count - 1) more poked you. \(left) on the newest."
        }
        if let notice = tagAlongs.first {
            return "\(names(notice.userID)) is tagging along to \(notice.planTitle)."
        }
        if let out = sent.first {
            switch out.state(at: now) {
            case .live(let remaining): return "Your poke to \(names(out.toID)) is out. \(PokeText.countdown(remaining))."
            case .acknowledged(_, .pokeBack): return "\(names(out.toID)) poked you back."
            case .acknowledged: return "\(names(out.toID)) saw your poke."
            case .expired: break
            }
        }
        return "Nobody is poking anybody. Start something."
    }
}
