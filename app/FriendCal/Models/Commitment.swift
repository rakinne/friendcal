import Foundation

/// What kind of hold on your time a commitment is. These three words are what the row shows, so the
/// labels live here rather than in the view -- the screen and the accessibility label read the same
/// string, and a VoiceOver test can assert it without rendering.
public enum CommitmentKind: String, Codable, Equatable, CaseIterable, Sendable {
    /// Your unexpired softHold on a plan still being decided. Can still evaporate.
    case held
    /// A Busy block a locked plan created. Settled: other people arranged around it.
    case locked
    /// A Busy block you made yourself. No plan behind it.
    case busy

    public var label: String {
        switch self {
        case .held: return "Held"
        case .locked: return "Locked"
        case .busy: return "Busy"
        }
    }

    /// Sort rank for same-time commitments: settled time outranks a maybe.
    var rank: Int {
        switch self {
        case .locked: return 0
        case .busy: return 1
        case .held: return 2
        }
    }
}

/// One line on "My commitments": a span of your time, what put it there, and (when you are allowed
/// to know) which plan.
///
/// `planTitle` is an INPUT, never a lookup. The server decides whether this caller may know the name
/// of the plan behind a commitment -- a block from a surprise being thrown for you is real and must
/// appear, but must stay nameless -- so the title arrives already authorized, or arrives nil. There
/// is deliberately no way to fetch it from here: a `title(for:)` helper on this type would be a hole
/// in the same boundary `my_commitments()` enforces in SQL.
public struct Commitment: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: CommitmentKind
    public var range: DateRange
    /// The plan that created this commitment, when one did. Nil for a Busy block you made yourself.
    public var sourceProposalID: UUID?
    /// The plan's name, when this viewer is allowed to see it. Nil means "a plan, but not yours to
    /// name" -- which is a different thing from `sourceProposalID == nil`, and the UI says so.
    public var planTitle: String?
    /// When a `held` commitment lapses. Nil never lapses.
    public var expiresAt: Date?

    public init(
        id: UUID = UUID(),
        kind: CommitmentKind,
        range: DateRange,
        sourceProposalID: UUID? = nil,
        planTitle: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.range = range
        self.sourceProposalID = sourceProposalID
        self.planTitle = planTitle
        self.expiresAt = expiresAt
    }

    /// True once `now` has reached `expiresAt`. Matches `AvailabilitySlot.isExpired(at:)` exactly,
    /// including the boundary: `expiresAt == now` is already gone.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    /// Whether this commitment is still claiming time at or after `horizon`.
    ///
    /// OVERLAP-based, deliberately. The obvious test -- "does it start at or after the horizon?" --
    /// drops a commitment that began before the horizon and is happening RIGHT NOW: anything
    /// overnight, or simply something that started an hour ago. Asking "am I committed from now on?"
    /// at 00:30 would answer "no" while you were in the middle of it. The bug is invisible except
    /// near a day boundary, which is exactly when the screen is most likely to be wrong.
    ///
    /// Half-open at the far end, matching the tstzrange `[)` the server stores: a commitment that
    /// ends exactly at the horizon is over.
    public func isLive(at horizon: Date) -> Bool {
        range.upperBound > horizon
    }
}

extension Commitment {
    /// The live commitments, in the order the screen draws them.
    ///
    /// Two filters, and they are not the same thing: `isLive` drops what is already over, `isExpired`
    /// drops a hold that lapsed while still pointing at future time. A hold for next Tuesday that
    /// expired this morning is in the future AND gone, and only the second filter catches it.
    public static func live(_ all: [Commitment], from horizon: Date, now: Date) -> [Commitment] {
        all.filter { $0.isLive(at: horizon) && !$0.isExpired(at: now) }
           .sorted(by: isOrderedBefore)
    }

    /// Four keys, in order: when it starts, when it ends, what kind it is, then id.
    ///
    /// The last two are not decoration. Without the kind key, a settled Locked row and a tentative
    /// Held row covering the same hour swap places between launches; without the id key, two
    /// commitments identical in all three leading keys order unstably, which makes a diffable list
    /// animate at random and makes any test that prints the list flaky. The sort is total.
    static func isOrderedBefore(_ a: Commitment, _ b: Commitment) -> Bool {
        if a.range.lowerBound != b.range.lowerBound { return a.range.lowerBound < b.range.lowerBound }
        if a.range.upperBound != b.range.upperBound { return a.range.upperBound < b.range.upperBound }
        if a.kind.rank != b.kind.rank { return a.kind.rank < b.kind.rank }
        return a.id.uuidString < b.id.uuidString
    }

    /// One day's worth of commitments, for the timeline's day headers.
    public struct Day: Identifiable, Equatable, Sendable {
        /// Start of the day, in the calendar used to group.
        public let date: Date
        public let commitments: [Commitment]
        public var id: Date { date }
    }

    /// Groups into days by the day a commitment STARTS in.
    ///
    /// An overnight commitment belongs to the evening it began, not the morning it ends: that is
    /// where someone looks for it, and listing it twice would double-count the week. It does mean a
    /// commitment can run past the end of its own day header, which is honest -- the row shows both
    /// ends -- and is why `live(_:from:now:)` filters on overlap rather than on the start.
    ///
    /// Takes the calendar as an argument so the screen can regroup on a timezone change without this
    /// type reading a global.
    public static func grouped(_ commitments: [Commitment], calendar: Calendar) -> [Day] {
        let sorted = commitments.sorted(by: isOrderedBefore)
        var days: [Day] = []
        for commitment in sorted {
            let start = calendar.startOfDay(for: commitment.range.lowerBound)
            if let last = days.last, last.date == start {
                days[days.count - 1] = Day(date: start, commitments: last.commitments + [commitment])
            } else {
                days.append(Day(date: start, commitments: [commitment]))
            }
        }
        return days
    }
}
