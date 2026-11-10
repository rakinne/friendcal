import Foundation

/// A status a person set: what, an optional away message, since when and until when (nil = until
/// they change it).
public struct FriendStatus: Equatable, Codable, Sendable {
    public static let maxMessageLength = 60

    public var kind: StatusKind
    public var message: String
    public var since: Date
    public var until: Date?

    /// The message is trimmed, newlines become spaces, and it stops at `maxMessageLength` characters.
    public init(kind: StatusKind, message: String = "", since: Date, until: Date? = nil) {
        self.kind = kind
        self.message = Self.clean(message)
        self.since = since
        self.until = until
    }

    public static func clean(_ text: String) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = flat.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(maxMessageLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Active until `until`; open-ended statuses stay active until their owner clears them.
    public func isActive(at now: Date) -> Bool {
        guard let until else { return true }
        return until > now
    }
}

/// How a friend reads on Groups right now. `busy` carries no payload by construction: a manual hold,
/// a hidden surprise plan and an expired status all read identically, so stacked "busy" rows reveal
/// nothing (X1, the stealth boundary).
public enum Presence: Equatable, Sendable {
    case status(FriendStatus)
    case busy
    case quiet

    /// A live status wins, because the person chose to say it. Otherwise busy if they are busy, else
    /// quiet. An expired status never survives into `busy`: its message must not leak after it ends.
    public static func resolve(status: FriendStatus?, isBusy: Bool, now: Date) -> Presence {
        if let status, status.isActive(at: now) { return .status(status) }
        return isBusy ? .busy : .quiet
    }

    /// The word beside the glyph.
    public var word: String {
        switch self {
        case .status(let s): s.kind.word
        case .busy: "busy"
        case .quiet: "quiet"
        }
    }

    public var status: FriendStatus? {
        if case .status(let s) = self { return s }
        return nil
    }
}

/// What a row prints under a name, computed here so the copy is tested, not eyeballed.
public struct RowText: Equatable, Sendable {
    /// The away message (italic). Nil when there is none to show.
    public var message: String?
    /// "till 11:00 PM", "since 7:30 PM", "free now" (mono). Nil for busy and quiet.
    public var time: String?
    /// One spoken sentence for the whole row.
    public var spoken: String
}

public extension Presence {
    func rowText(name: String, isYou: Bool = false, now: Date, calendar: Calendar = .current) -> RowText {
        let who = isYou ? "You" : name
        switch self {
        case .status(let s):
            let time: String
            if let until = s.until {
                time = "till \(TimeText.clock(until, calendar: calendar))"
            } else if s.kind == .free {
                time = "free now"
            } else {
                time = "since \(TimeText.clock(s.since, calendar: calendar))"
            }
            let message = s.message.isEmpty ? nil : s.message
            var spoken = "\(who), \(s.kind.word), \(time)"
            if let message { spoken += ", \(message)" }
            return RowText(message: message, time: time, spoken: spoken)
        case .busy:
            return RowText(message: nil, time: nil, spoken: "\(who), busy")
        case .quiet:
            return RowText(message: isYou ? "set your status" : nil, time: nil,
                           spoken: isYou ? "You, no status yet. Double tap to set one" : "\(who), no status")
        }
    }
}

/// How long a new status lasts. The sheet defaults to two hours.
public enum StatusDuration: Equatable, CaseIterable, Sendable {
    case oneHour, twoHours, tonight, allNight

    /// When it ends. `tonight` is 11 PM, or midnight when 11 PM is under 30 minutes away. `allNight`
    /// is 7 AM, the next one at least 30 minutes away.
    public func end(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .twoHours: return now.addingTimeInterval(7200)
        case .tonight:
            let night = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: now) ?? now
            if night.timeIntervalSince(now) >= 30 * 60 { return night }
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? night
        case .allNight:
            let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: now) ?? now
            if morning.timeIntervalSince(now) >= 30 * 60 { return morning }
            return calendar.date(byAdding: .day, value: 1, to: morning) ?? morning
        }
    }

    public func label(from now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .tonight: "till \(TimeText.clock(end(from: now, calendar: calendar), calendar: calendar, short: true))"
        case .allNight: "all night"
        }
    }
}

/// Clock and duration wording shared by rows, Moments and the status sheet. Fixed `en_US_POSIX`
/// patterns, like the chip words, so the copy is the same in every locale and under test.
public enum TimeText {
    /// "11:00 PM", or "11 PM" when `short` and on the hour.
    public static func clock(_ date: Date, calendar: Calendar = .current, short: Bool = false) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        let onTheHour = calendar.component(.minute, from: date) == 0
        f.dateFormat = short && onTheHour ? "h a" : "h:mm a"
        return f.string(from: date)
    }

    /// "40 min", "1 h 30", "2 h". Never "0 min": under a minute reads "1 min".
    public static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let (h, m) = minutes.quotientAndRemainder(dividingBy: 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m)"
    }
}
