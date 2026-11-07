import Foundation

/// A validated create request (D4): what `ProposalStore.create` persists.
public struct NewProposal: Equatable {
    public let title: String
    public let window: DateRange
    public let expectedCount: Int

    public init(title: String, window: DateRange, expectedCount: Int) {
        self.title = title
        self.window = window
        self.expectedCount = expectedCount
    }
}

/// The create / edit form state (D4, D13, design 5.4A). Pure: every rule has a unit test.
///
/// Dates are date-only: `from` snaps to the start of its day and `to` to the last second of its day,
/// and the <= 45-day bound counts calendar days of the snapped values. The title never carries the
/// trailing "?" the app appends while a plan is requesting (design 2.1A); blank means "Brunch".
public struct ProposalDraft: Equatable {
    public static let defaultTitle = "Brunch"
    public static let maxDays = 45
    public static let minimumExpected = 2
    public static let defaultExpected = 8

    public enum ValidationError: Error, Equatable {
        case endBeforeStart
        case tooLong(days: Int)
        case tooFewPeople
    }

    public var title: String
    public var from: Date
    public var to: Date
    /// Inclusive of the creator (design 3.3A: "How many people, counting you?").
    public var expectedCount: Int

    public init(title: String = "", from: Date, to: Date, expectedCount: Int = ProposalDraft.defaultExpected) {
        self.title = title
        self.from = from
        self.to = to
        self.expectedCount = expectedCount
    }

    /// Next Monday for two weeks (D4), 8 people.
    public static func `default`(now: Date, calendar: Calendar) -> ProposalDraft {
        var cal = calendar
        cal.firstWeekday = 2
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today) // 1 = Sunday ... 2 = Monday
        let daysToMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        let monday = cal.date(byAdding: .day, value: daysToMonday, to: today)!
        let end = cal.date(byAdding: .day, value: 13, to: monday)!
        return ProposalDraft(from: monday, to: end)
    }

    /// Editing an existing plan (design 5.4A). The count starts at least at the people already
    /// joined (the quorum base is max(expected, joined)), so a title-only edit never needs the
    /// creator to bump a number they did not touch.
    public init(editing proposal: Proposal) {
        title = proposal.title
        from = proposal.window.lowerBound
        to = proposal.window.upperBound
        expectedCount = max(proposal.expectedCount, proposal.joinedCount)
    }

    /// "Brunch" when blank; trailing "?" and whitespace stripped.
    public var cleanTitle: String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("?") { t = String(t.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        return t.isEmpty ? Self.defaultTitle : t
    }

    /// The day-snapped window: [startOfDay(from), startOfDay(to) + 1 day - 1 s].
    public func window(calendar: Calendar) -> DateRange {
        let lower = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        let upper = calendar.date(byAdding: .day, value: 1, to: toDay)!.addingTimeInterval(-1)
        return DateRange(lower: lower, upper: upper)
    }

    /// Calendar days from `from`'s day through `to`'s day, inclusive (1 for a same-day window).
    public func dayCount(calendar: Calendar) -> Int {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        return (calendar.dateComponents([.day], from: fromDay, to: toDay).day ?? 0) + 1
    }

    public func validate(calendar: Calendar) throws -> NewProposal {
        let days = dayCount(calendar: calendar)
        if days < 1 { throw ValidationError.endBeforeStart }
        if days > Self.maxDays { throw ValidationError.tooLong(days: days) }
        if expectedCount < Self.minimumExpected { throw ValidationError.tooFewPeople }
        return NewProposal(title: cleanTitle, window: window(calendar: calendar), expectedCount: expectedCount)
    }

    /// Per-field errors for inline presentation (design 5.4A); empty when valid.
    public func errors(calendar: Calendar) -> [ValidationError] {
        var out: [ValidationError] = []
        let days = dayCount(calendar: calendar)
        if days < 1 { out.append(.endBeforeStart) } else if days > Self.maxDays { out.append(.tooLong(days: days)) }
        if expectedCount < Self.minimumExpected { out.append(.tooFewPeople) }
        return out
    }
}
