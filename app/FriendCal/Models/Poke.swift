import Foundation

/// A poke: one nudge from one friend to another, alive for an hour.
///
///     sendPoke ──> live ──acknowledge (push tap, "Got it")──> acknowledged
///                   │   ──the other person pokes back───────> acknowledged
///                   └───── an hour passes ──────────────────> expired
///
/// The state is DERIVED from three dates and never stored, here or in `pokes` (supabase/social.sql):
/// a stored "live" flag would need something to flip it at the hour, and a phone that was asleep at
/// the hour would go on showing a poke that had already faded. Acknowledged wins over expired, so a
/// poke that was seen at minute 59 still reads "seen" at minute 61.
public struct Poke: Identifiable, Equatable, Codable, Sendable {
    /// How long a poke stays answerable. Matches `c_lifetime` in send_poke().
    public static let lifetime: TimeInterval = 3600

    /// How the recipient closed it. `pokeBack` is written by the server when they poke the sender.
    public enum AckVia: String, Codable, Sendable {
        case push
        case app
        case pokeBack = "poke_back"
    }

    public enum State: Equatable, Sendable {
        case live(remaining: TimeInterval)
        case acknowledged(at: Date, via: AckVia)
        case expired
    }

    public var id: UUID
    public var fromID: UUID
    public var toID: UUID
    /// The plan it is about, only when both people can read that plan.
    public var proposalID: UUID?
    public var createdAt: Date
    public var expiresAt: Date
    public var acknowledgedAt: Date?
    public var ackVia: AckVia?

    public init(id: UUID = UUID(), fromID: UUID, toID: UUID, proposalID: UUID? = nil, createdAt: Date,
                expiresAt: Date? = nil, acknowledgedAt: Date? = nil, ackVia: AckVia? = nil) {
        self.id = id
        self.fromID = fromID
        self.toID = toID
        self.proposalID = proposalID
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.lifetime)
        self.acknowledgedAt = acknowledgedAt
        self.ackVia = ackVia
    }

    /// `expiresAt == now` is already expired, like `AvailabilitySlot.isExpired(at:)`.
    public func state(at now: Date) -> State {
        if let acknowledgedAt { return .acknowledged(at: acknowledgedAt, via: ackVia ?? .app) }
        let remaining = expiresAt.timeIntervalSince(now)
        return remaining > 0 ? .live(remaining: remaining) : .expired
    }

    public func isLive(at now: Date) -> Bool {
        if case .live = state(at: now) { return true }
        return false
    }

    /// 1 just after sending, 0 at the hour. Drives the fuse under a live poke.
    public func fuse(at now: Date) -> Double {
        guard case .live(let remaining) = state(at: now) else { return 0 }
        let span = expiresAt.timeIntervalSince(createdAt)
        return span > 0 ? min(1, max(0, remaining / span)) : 0
    }
}

/// What `sendPoke` answers. `isNew` is false when a live poke to that friend already existed and
/// was returned instead: no second row, no second push.
public struct PokeReceipt: Equatable, Sendable {
    public var poke: Poke
    public var isNew: Bool

    public init(poke: Poke, isNew: Bool) {
        self.poke = poke
        self.isNew = isNew
    }
}

/// Every word a poke puts on screen, so Home, Groups, the Pokes tab and VoiceOver say the same
/// thing and the copy is tested rather than eyeballed.
public enum PokeText {
    /// "58 min left". A poke with seconds to go still reads "1 min left", never "0 min".
    public static func countdown(_ remaining: TimeInterval) -> String {
        "\(TimeText.span(min(remaining, Poke.lifetime))) left"
    }

    /// The toast after a poke, identical wherever it was sent from.
    public static func sent(name: String, receipt: PokeReceipt, now: Date) -> String {
        if receipt.isNew { return "Poked \(name). It fades in an hour." }
        if case .live(let remaining) = receipt.poke.state(at: now) {
            return "\(name) already has your poke. \(countdown(remaining))."
        }
        return "\(name) already has your poke."
    }

    /// The badge word on a poke you sent.
    public static func sentWord(_ state: Poke.State) -> String {
        switch state {
        case .live: "POKED"
        case .acknowledged(_, .pokeBack): "POKED BACK"
        case .acknowledged: "SEEN"
        case .expired: "FADED"
        }
    }

    /// The badge word on a poke you received.
    public static func receivedWord(_ state: Poke.State) -> String {
        switch state {
        case .live: "POKED YOU"
        case .acknowledged(_, .pokeBack): "YOU POKED BACK"
        case .acknowledged: "YOU SAW IT"
        case .expired: "FADED"
        }
    }

    /// The mono line beside the word: time left while live, how long ago otherwise.
    public static func timeLine(_ poke: Poke, now: Date) -> String {
        switch poke.state(at: now) {
        case .live(let remaining): countdown(remaining)
        case .acknowledged(let at, _): ago(at, now: now)
        case .expired: ago(poke.expiresAt, now: now)
        }
    }

    /// "just now", "12 min ago", "3 h ago".
    public static func ago(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        return elapsed < 60 ? "just now" : "\(TimeText.span(elapsed)) ago"
    }

    /// One spoken sentence for a received poke's row.
    public static func spokenReceived(name: String, plan: String?, poke: Poke, now: Date) -> String {
        let about = plan.map { " about \($0)" } ?? ""
        switch poke.state(at: now) {
        case .live(let remaining): return "\(name) poked you\(about), \(countdown(remaining))"
        case .acknowledged(_, .pokeBack): return "\(name) poked you\(about). You poked back"
        case .acknowledged: return "\(name) poked you\(about). You saw it"
        case .expired: return "\(name) poked you\(about). It faded"
        }
    }

    /// One spoken sentence for a sent poke's row.
    public static func spokenSent(name: String, poke: Poke, now: Date) -> String {
        switch poke.state(at: now) {
        case .live(let remaining): "You poked \(name), \(countdown(remaining))"
        case .acknowledged(_, .pokeBack): "You poked \(name). They poked back"
        case .acknowledged: "You poked \(name). They saw it"
        case .expired: "You poked \(name). It faded"
        }
    }
}

/// Who Home's Poke offers, in order: friends who have not answered the plan first, because that is
/// what a poke is for (premise 6), then everyone else. Within each group the given order is kept.
public struct PokeTarget: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// On a plan that is still collecting times, and has marked none.
    public var isWaiting: Bool

    public static func order(members: [(id: UUID, name: String)], answered: Set<UUID>, me: UUID?,
                             isCollecting: Bool) -> [PokeTarget] {
        let others = members.filter { $0.id != me }
            .map { PokeTarget(id: $0.id, name: $0.name, isWaiting: isCollecting && !answered.contains($0.id)) }
        return others.filter(\.isWaiting) + others.filter { !$0.isWaiting }
    }
}
