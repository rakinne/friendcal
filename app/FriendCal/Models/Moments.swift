import Foundation

/// The one live line at the top of Groups. It replaces a "Maya signed on" ticker with something to
/// act on, built from overlap (FriendCal's whole point) and from what is ending soon.
public struct Moment: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case poke(UUID, name: String)
        case setStatus
        case invite

        public var label: String {
            switch self {
            case .poke(_, let name): "Poke \(name)"
            case .setStatus: "Set status"
            case .invite: "Add a friend"
            }
        }
    }

    public var text: String
    /// A friend's own words, shown italic under the line ("down for tacos, anyone").
    public var detail: String?
    public var action: Action?

    public init(text: String, detail: String? = nil, action: Action? = nil) {
        self.text = text
        self.detail = detail
        self.action = action
    }
}

public enum MomentsEngine {
    /// How far ahead "ending soon" looks, and the shortest stay worth mentioning.
    static let soon: TimeInterval = 3 * 3600
    static let minStay: TimeInterval = 20 * 60

    /// Picks the moment, in priority order:
    /// 1. You and a friend are both free: "You and Arlo are both free right now."
    /// 2. Something ends soon, plus the longest current stay: "Leo's movie lets out in 1 h 30. Nina has been at the concert for 40 min."
    /// 3. Friends exist but nobody has said anything: a nudge to set yours (or a quiet note if you did).
    /// 4. No friends yet: a nudge to invite the first.
    ///
    /// `viewerFree` means no live status other than "free" and not busy. Busy and quiet friends never
    /// appear in a line, so a moment cannot leak what a plain "busy" hides.
    public static func moment(friends: [Buddy], presence: (UUID) -> Presence, viewerFree: Bool,
                              viewerHasStatus: Bool = false, now: Date, calendar: Calendar = .current) -> Moment {
        guard !friends.isEmpty else {
            return Moment(text: "Quiet in here. Invite your first friend.", detail: nil, action: .invite)
        }
        let live: [(buddy: Buddy, status: FriendStatus)] = friends.compactMap { buddy in
            presence(buddy.id).status.map { (buddy, $0) }
        }

        if viewerFree, let pal = live.first(where: { $0.status.kind == .free }) {
            let tail = pal.status.until.map { " till \(TimeText.clock($0, calendar: calendar, short: true))" } ?? " right now"
            return Moment(text: "You and \(pal.buddy.name) are both free\(tail).",
                          detail: pal.status.message.isEmpty ? nil : pal.status.message,
                          action: .poke(pal.buddy.id, name: pal.buddy.name))
        }

        var sentences: [String] = []
        var named: UUID?
        let ending = live.compactMap { item -> (Buddy, FriendStatus, TimeInterval)? in
            guard item.status.kind != .free, let until = item.status.until else { return nil }
            let left = until.timeIntervalSince(now)
            return left > 0 && left <= soon ? (item.buddy, item.status, left) : nil
        }.min { $0.2 < $1.2 }
        if let (buddy, status, left) = ending {
            let lead = status.kind == .movies ? "\(buddy.name)'s movie lets out" : "\(buddy.name)'s \(status.kind.endNoun) ends"
            sentences.append("\(lead) in \(TimeText.span(left)).")
            named = buddy.id
        }
        let stay = live.compactMap { item -> (Buddy, FriendStatus, TimeInterval)? in
            guard item.buddy.id != named, item.status.kind != .free else { return nil }
            let been = now.timeIntervalSince(item.status.since)
            return been >= minStay ? (item.buddy, item.status, been) : nil
        }.max { $0.2 < $1.2 }
        if let (buddy, status, been) = stay {
            sentences.append("\(buddy.name) has been \(status.kind.stayPhrase) for \(TimeText.span(been)).")
        }
        if !sentences.isEmpty {
            return Moment(text: sentences.joined(separator: " "), detail: nil, action: nil)
        }
        if viewerHasStatus {
            return Moment(text: "Nobody else has set a status yet.", detail: nil, action: nil)
        }
        return Moment(text: "Nobody has set a status yet. Be the first.", detail: nil, action: .setStatus)
    }
}

/// One stretch of a friend's day, as a 0...1 fraction of the day, for the 24-hour ribbon on a
/// friend's card. Only their own live status and their public busy time ever land here: a Stealth
/// plan arrives as plain busy time like any other, so the ribbon cannot name it.
public struct RibbonSegment: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case status(StatusKind)
        case busy
    }

    public var kind: Kind
    public var start: Double
    public var end: Double
}

public enum DayRibbon {
    /// 0...1 across today's calendar day.
    public static func fraction(of date: Date, now: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let span = end.timeIntervalSince(start)
        return min(1, max(0, date.timeIntervalSince(start) / span))
    }

    /// Busy time first, then the status on top. Everything is clipped to today; an open-ended status
    /// is drawn up to now. Stretches under about 15 minutes are widened so they stay visible.
    public static func segments(status: FriendStatus?, busy: [DateInterval], now: Date,
                                calendar: Calendar = .current) -> [RibbonSegment] {
        func segment(_ kind: RibbonSegment.Kind, _ from: Date, _ to: Date) -> RibbonSegment? {
            let a = fraction(of: from, now: now, calendar: calendar)
            let b = fraction(of: to, now: now, calendar: calendar)
            guard b > a else { return nil }
            let minWidth = 15.0 * 60 / 86_400
            return RibbonSegment(kind: kind, start: a, end: min(1, max(b, a + minWidth)))
        }
        var result = busy.compactMap { segment(.busy, $0.start, $0.end) }
        if let status, status.isActive(at: now), let s = segment(.status(status.kind), status.since, status.until ?? now) {
            result.append(s)
        }
        return result
    }
}
