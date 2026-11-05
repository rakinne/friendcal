import Foundation

/// Codable/Hashable range replacement for ClosedRange<Date> which is not Codable.
struct DateRange: Codable, Equatable, Hashable {
    var lowerBound: Date
    var upperBound: Date
    init(_ range: ClosedRange<Date>) {
        self.lowerBound = range.lowerBound
        self.upperBound = range.upperBound
    }
    init(lower: Date, upper: Date) { self.lowerBound = lower; self.upperBound = upper }
    var asClosedRange: ClosedRange<Date> { lowerBound...upperBound }
    func overlaps(_ other: DateRange) -> Bool {
        lowerBound <= other.upperBound && other.lowerBound <= upperBound
    }
}
