import Foundation

/// Share messages. One title rule (`Proposal.displayTitle`, design 2.1A) and one set of date
/// formatters (`DateText`) serve every surface.
public enum ShareText {
    /// The Share slot message (X9): "Brunch? Sat, Nov 15 · 10:00-11:30 AM works for 13 of 15".
    /// Names the date and the common window the N friends actually share (D12, D13).
    /// nil when the cell can't be shared (HeatmapSelection.canShare).
    public static func format(title: String, cell: HeatmapCell, calendar: Calendar, locale: Locale) -> String? {
        guard HeatmapSelection.canShare(cell), let window = cell.commonWindow else { return nil }
        let day = DateText.day(window.lowerBound, calendar: calendar, locale: locale)
        let time = DateText.timeRange(window, calendar: calendar, locale: locale, separator: "-")
        return "\(Proposal.displayTitle(title, isLocked: false)) \(day) · \(time) works for \(cell.commonCount) of \(cell.total)"
    }

    /// The invite message (design 3.5A), everywhere a link is shared:
    /// "Brunch? Mark when you're free in FriendCal: friendcal://proposal/<id>".
    public static func invite(title: String, url: URL) -> String {
        "\(Proposal.displayTitle(title, isLocked: false)) Mark when you're free in FriendCal: \(url.absoluteString)"
    }

    /// Home's Share once a plan is locked (design 2.2A): "Brunch is locked: Sat, Nov 14 · 10:00 AM-12:00 PM".
    /// With a winning place the message ends " at <name>" (design PL-7); without one it is unchanged.
    public static func locked(title: String, window: DateRange, calendar: Calendar, locale: Locale, place: String? = nil) -> String {
        let day = DateText.day(window.lowerBound, calendar: calendar, locale: locale)
        let time = DateText.timeRange(window, calendar: calendar, locale: locale, separator: "-")
        return "\(Proposal.displayTitle(title, isLocked: true)) is locked: \(day) · \(time)\(place.map { " at \($0)" } ?? "")"
    }
}
