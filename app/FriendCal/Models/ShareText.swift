import Foundation

/// The Share slot message (X9): "Brunch? Sat, Nov 15 · 10:00-11:30 AM works for 13 of 15".
/// Names the date and the common window the N friends actually share (D12, D13).
public enum ShareText {
    /// nil when the cell can't be shared (HeatmapSelection.canShare).
    public static func format(title: String, cell: HeatmapCell, calendar: Calendar, locale: Locale) -> String? {
        guard HeatmapSelection.canShare(cell), let window = cell.commonWindow else { return nil }

        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("EEEMMMd")

        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")

        var start = normalize(time.string(from: window.lowerBound))
        let end = normalize(time.string(from: window.upperBound))
        // "10:00 AM-11:30 AM" reads as "10:00-11:30 AM" when both share a day period.
        for symbol in [time.amSymbol, time.pmSymbol].compactMap({ $0 }) where !symbol.isEmpty {
            if start.hasSuffix(symbol) && end.hasSuffix(symbol) {
                start = String(start.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return "\(title)? \(normalize(day.string(from: window.lowerBound))) · \(start)-\(end) works for \(cell.commonCount) of \(cell.total)"
    }

    /// Formatters emit narrow no-break spaces (U+202F) before AM/PM; messages use plain spaces.
    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
