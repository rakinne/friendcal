import Foundation

/// The three bookable parts of a day, in local wall-clock hours. 23:00-06:00 is ignored.
public enum Daypart: Int, CaseIterable, Comparable, Sendable {
    case morning, afternoon, evening

    /// [startHour, endHour) on the local clock.
    public var hours: (start: Int, end: Int) {
        switch self {
        case .morning: return (6, 12)
        case .afternoon: return (12, 17)
        case .evening: return (17, 23)
        }
    }

    public static func < (lhs: Daypart, rhs: Daypart) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Fill bucket for a cell, by coverage = commonCount / total (D13).
/// [0, 0.25) peachLight, [0.25, 0.5) peach, [0.5, 0.75) orange #FF6A32, [0.75, 1] primary.
public enum HeatmapRamp: Equatable, Sendable {
    case peachLight, peach, orange, primary

    public init(coverage: Double) {
        switch coverage {
        case ..<0.25: self = .peachLight
        case ..<0.5: self = .peach
        case ..<0.75: self = .orange
        default: self = .primary
        }
    }
}

/// A recipient's status in one cell (X2). Derived only from this proposal's eligible softHolds (D9):
/// BusyBlocks are never read, so busy, a hidden plan and no reply all look identical (X1).
public enum CellStatus: Equatable, Sendable {
    /// An eligible slot covers the cell's commonWindow. The number of `.free` equals commonCount.
    case free
    /// Not free; their earliest eligible time in the cell starts at this date, after the common
    /// window's start (or after the cell's start when there is no common window).
    case after(Date)
    /// Not free and not after: has an eligible slot in the cell that misses the common window.
    case maybe
    /// No eligible slot intersecting the cell (X1).
    case busy
}

/// One day x daypart cell of the heatmap grid.
public struct HeatmapCell: Identifiable, Equatable {
    public struct ID: Hashable {
        public let day: Date
        public let daypart: Daypart
    }

    public var id: ID { ID(day: day, daypart: daypart) }
    /// Start of the local day.
    public let day: Date
    public let daypart: Daypart
    /// The daypart interval clipped to the proposal window (D11). nil = disabled (no positive-duration overlap).
    public let interval: DateRange?
    /// Recipients with any eligible slot intersecting `interval`. Computed, not displayed (D13).
    public let freeCount: Int
    /// Recipients sharing `commonWindow` (D12). Drives the label, VoiceOver, ramp, best and lock quorum (D13).
    public let commonCount: Int
    /// The earliest >= 60-min window inside `interval` shared by the most recipients. nil when commonCount == 0.
    public let commonWindow: DateRange?
    /// The quorum base: max(expected headcount, distinct recipients) (D5, #5 D13).
    public let total: Int
    public internal(set) var isBest: Bool
    /// Every recipient's status in this cell (X2). Empty for disabled cells.
    public let roster: [UUID: CellStatus]

    public init(day: Date, daypart: Daypart, interval: DateRange?, freeCount: Int, commonCount: Int, commonWindow: DateRange?, total: Int, isBest: Bool = false, roster: [UUID: CellStatus] = [:]) {
        self.day = day
        self.daypart = daypart
        self.interval = interval
        self.freeCount = freeCount
        self.commonCount = commonCount
        self.commonWindow = commonWindow
        self.total = total
        self.isBest = isBest
        self.roster = roster
    }

    public var isEnabled: Bool { interval != nil }
    /// commonCount / total; 0 when total == 0 (the cell renders "–").
    public var coverage: Double { total == 0 ? 0 : Double(commonCount) / Double(total) }
    /// nil for disabled cells (no fill).
    public var ramp: HeatmapRamp? { isEnabled ? HeatmapRamp(coverage: coverage) : nil }
    /// Where a lock on this cell starts (D12).
    public var lockTarget: Date? { commonWindow?.lowerBound }
}

/// One Monday-first week: always 21 cells, ordered day-major (Mon morning, Mon afternoon, ..., Sun evening).
public struct HeatmapWeek: Identifiable, Equatable {
    public var id: Date { weekStart }
    public let weekStart: Date
    public let cells: [HeatmapCell]

    public init(weekStart: Date, cells: [HeatmapCell]) {
        self.weekStart = weekStart
        self.cells = cells
    }

    public var best: HeatmapCell? { cells.first(where: \.isBest) }

    /// dayIndex 0 = Monday.
    public func cell(dayIndex: Int, daypart: Daypart) -> HeatmapCell {
        cells[dayIndex * Daypart.allCases.count + daypart.rawValue]
    }
}

/// Pure heatmap math (D6). Callers inject `now` and the calendar, so tests pin the timezone.
public enum HeatmapBuilder {
    /// Shortest shared window that counts as a common meeting time (D12).
    public static let minimumCommonDuration: TimeInterval = 60 * 60

    /// Buckets this proposal's eligible slots into Monday-first weeks covering `window`.
    ///
    /// Eligible (D9): `.softHold`, `sourceProposalID == proposalID`, `userID` in `recipientIDs`,
    /// and `expiresAt` nil or after `now`. A slot counts in a cell when it `intersects` the cell's
    /// `interval` (D10). Each recipient counts at most once per cell. total = max(expectedCount,
    /// distinct recipients): the crew the creator expects, or everyone who joined if more did
    /// (issue #5 D13, amending #4 D5; 0 means recipients only).
    /// Best per week (D13) = highest commonCount among enabled cells, ties to the earliest day then
    /// daypart; no best when every count is 0. Each enabled cell's roster gives every recipient a
    /// CellStatus (see CellStatus for the rules).
    public static func weeks(slots: [AvailabilitySlot], window: DateRange, recipientIDs: [UUID], expectedCount: Int = 0, proposalID: UUID, now: Date, calendar: Calendar) -> [HeatmapWeek] {
        guard window.lowerBound < window.upperBound else { return [] }
        var cal = calendar
        cal.firstWeekday = 2 // weeks start Monday regardless of locale

        let ordered = distinct(recipientIDs)
        let recipients = Set(ordered)
        let total = max(expectedCount, ordered.count)
        let eligible = slots.filter { isEligible($0, proposalID: proposalID, recipients: recipients, now: now) }

        guard var weekStart = cal.dateInterval(of: .weekOfYear, for: window.lowerBound)?.start else { return [] }
        var weeks: [HeatmapWeek] = []
        while weekStart < window.upperBound {
            weeks.append(week(starting: weekStart, window: window, slots: eligible, recipients: ordered, total: total, calendar: cal))
            guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: weekStart) else { break }
            weekStart = next
        }
        return weeks
    }

    private static func week(starting weekStart: Date, window: DateRange, slots: [AvailabilitySlot], recipients: [UUID], total: Int, calendar: Calendar) -> HeatmapWeek {
        var cells: [HeatmapCell] = []
        cells.reserveCapacity(21)
        for dayIndex in 0..<7 {
            let day = calendar.date(byAdding: .day, value: dayIndex, to: weekStart)!
            for daypart in Daypart.allCases {
                cells.append(cell(day: day, daypart: daypart, window: window, slots: slots, recipients: recipients, total: total, calendar: calendar))
            }
        }
        if let bestIndex = bestIndex(in: cells) { cells[bestIndex].isBest = true }
        return HeatmapWeek(weekStart: weekStart, cells: cells)
    }

    private static func cell(day: Date, daypart: Daypart, window: DateRange, slots: [AvailabilitySlot], recipients: [UUID], total: Int, calendar: Calendar) -> HeatmapCell {
        guard let interval = daypartInterval(day: day, daypart: daypart, calendar: calendar).flatMap({ clip($0, to: window) }) else {
            return HeatmapCell(day: day, daypart: daypart, interval: nil, freeCount: 0, commonCount: 0, commonWindow: nil, total: total)
        }
        // Per recipient: their slots clipped to the cell, merged so overlapping/touching slots count once.
        var byUser: [UUID: [DateRange]] = [:]
        for s in slots where s.range.intersects(interval) {
            if let clipped = clip(s.range, to: interval) { byUser[s.userID, default: []].append(clipped) }
        }
        let merged = byUser.mapValues(merge)
        let (count, common) = commonWindow(Array(merged.values))
        let anchor = common?.lowerBound ?? interval.lowerBound
        var roster: [UUID: CellStatus] = [:]
        for id in recipients {
            guard let ranges = merged[id], let first = ranges.first else { roster[id] = .busy; continue }
            if let w = common, ranges.contains(where: { $0.lowerBound <= w.lowerBound && w.upperBound <= $0.upperBound }) {
                roster[id] = .free
            } else if first.lowerBound > anchor {
                roster[id] = .after(first.lowerBound)
            } else {
                roster[id] = .maybe
            }
        }
        return HeatmapCell(day: day, daypart: daypart, interval: interval, freeCount: byUser.count, commonCount: count, commonWindow: common, total: total, roster: roster)
    }

    /// The window shared by the most recipients that lasts >= minimumCommonDuration; earliest wins ties.
    /// Candidate starts are the recipients' interval starts: an optimal window can always slide left
    /// until it hits one. Returns the full shared span for that set of recipients.
    static func commonWindow(_ coverage: [[DateRange]]) -> (count: Int, window: DateRange?) {
        let candidates = Set(coverage.flatMap { $0.map(\.lowerBound) }).sorted()
        var best: (count: Int, window: DateRange?) = (0, nil)
        for t in candidates {
            let end = t.addingTimeInterval(minimumCommonDuration)
            let covering = coverage.compactMap { ranges in ranges.first { $0.lowerBound <= t && end <= $0.upperBound } }
            guard covering.count > best.count else { continue }
            let lower = covering.map(\.lowerBound).max()!
            let upper = covering.map(\.upperBound).min()!
            best = (covering.count, DateRange(lower: lower, upper: upper))
        }
        return best
    }

    private static func bestIndex(in cells: [HeatmapCell]) -> Int? {
        var best: Int?
        for (i, c) in cells.enumerated() where c.isEnabled && c.commonCount > 0 {
            if best == nil || c.commonCount > cells[best!].commonCount { best = i }
        }
        return best
    }

    private static func daypartInterval(day: Date, daypart: Daypart, calendar: Calendar) -> DateRange? {
        guard let start = calendar.date(bySettingHour: daypart.hours.start, minute: 0, second: 0, of: day),
              let end = calendar.date(bySettingHour: daypart.hours.end, minute: 0, second: 0, of: day) else { return nil }
        return DateRange(lower: start, upper: end)
    }

    /// Positive-duration intersection, or nil.
    private static func clip(_ range: DateRange, to bounds: DateRange) -> DateRange? {
        let lower = max(range.lowerBound, bounds.lowerBound)
        let upper = min(range.upperBound, bounds.upperBound)
        return lower < upper ? DateRange(lower: lower, upper: upper) : nil
    }

    /// Recipient IDs in first-seen order, duplicates dropped (D5).
    static func distinct(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// D9 eligibility, shared with lock promotion so quorum and promotion count the same holds:
    /// this proposal's unexpired softHold from a recipient.
    static func isEligible(_ s: AvailabilitySlot, proposalID: UUID, recipients: Set<UUID>, now: Date) -> Bool {
        s.state == .softHold
            && s.sourceProposalID == proposalID
            && recipients.contains(s.userID)
            && (s.expiresAt.map { $0 > now } ?? true)
    }

    /// Sorted union; touching ranges join.
    static func merge(_ ranges: [DateRange]) -> [DateRange] {
        var out: [DateRange] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1].upperBound = max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}
