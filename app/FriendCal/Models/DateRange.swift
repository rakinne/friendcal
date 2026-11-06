import Foundation

/// Codable/Hashable range replacement for ClosedRange<Date> which is not Codable.
public struct DateRange: Codable, Equatable, Hashable {
    public var lowerBound: Date
    public var upperBound: Date
    public init(_ range: ClosedRange<Date>) {
        self.lowerBound = range.lowerBound
        self.upperBound = range.upperBound
    }
    public init(lower: Date, upper: Date) { self.lowerBound = lower; self.upperBound = upper }
    public var asClosedRange: ClosedRange<Date> { lowerBound...upperBound }
    public func overlaps(_ other: DateRange) -> Bool {
        lowerBound <= other.upperBound && other.lowerBound <= upperBound
    }
}
