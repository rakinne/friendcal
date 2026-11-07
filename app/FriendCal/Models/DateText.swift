import Foundation

/// Date and time copy shared by the share text and the invite screens, so one rule formats a day,
/// a time range and a duration everywhere.
public enum DateText {
    /// "Sat, Nov 14".
    public static func day(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        normalize(formatter("EEEMMMd", calendar: calendar, locale: locale).string(from: date))
    }

    /// "Saturday".
    public static func weekday(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        normalize(formatter("EEEE", calendar: calendar, locale: locale).string(from: date))
    }

    /// "10:00 AM–12:00 PM", collapsing a shared day period to "10:00–11:30 AM".
    public static func timeRange(_ range: DateRange, calendar: Calendar, locale: Locale, separator: String = "–") -> String {
        let time = formatter("jmm", calendar: calendar, locale: locale)
        var start = normalize(time.string(from: range.lowerBound))
        let end = normalize(time.string(from: range.upperBound))
        for symbol in [time.amSymbol, time.pmSymbol].compactMap({ $0 }) where !symbol.isEmpty {
            if start.hasSuffix(symbol) && end.hasSuffix(symbol) {
                start = String(start.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return "\(start)\(separator)\(end)"
    }

    /// "Nov 9–22" or "Nov 30–Dec 6".
    public static func dayRange(_ range: DateRange, calendar: Calendar, locale: Locale) -> String {
        let f = formatter("MMMd", calendar: calendar, locale: locale)
        let sameMonth = calendar.component(.month, from: range.lowerBound) == calendar.component(.month, from: range.upperBound)
            && calendar.component(.year, from: range.lowerBound) == calendar.component(.year, from: range.upperBound)
        let endText = sameMonth ? String(calendar.component(.day, from: range.upperBound)) : normalize(f.string(from: range.upperBound))
        return "\(normalize(f.string(from: range.lowerBound)))–\(endText)"
    }

    /// "2 h", "1 h 30", "1 h 20", "45 min".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m)"
    }

    /// "Sat morning" (short) or "Saturday morning" (long).
    public static func dayPart(day: Date, daypart: Daypart, calendar: Calendar, locale: Locale, long: Bool = false) -> String {
        let name = normalize(formatter(long ? "EEEE" : "EEE", calendar: calendar, locale: locale).string(from: day))
        return "\(name) \(daypart)"
    }

    static func formatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// Formatters emit narrow no-break spaces (U+202F) before AM/PM; messages use plain spaces.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
