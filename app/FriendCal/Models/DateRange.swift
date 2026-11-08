import Foundation

/// Codable/Hashable range replacement for ClosedRange<Date> which is not Codable.
/// `Sendable` because it is two `Date` values and nothing else; declaring it keeps `Commitment` and
/// anything else that crosses an isolation boundary from warning (an error in Swift 6 mode).
public struct DateRange: Codable, Equatable, Hashable, Sendable {
    public var lowerBound: Date
    public var upperBound: Date
    public init(_ range: ClosedRange<Date>) {
        self.lowerBound = range.lowerBound
        self.upperBound = range.upperBound
    }
    public init(lower: Date, upper: Date) { self.lowerBound = lower; self.upperBound = upper }
    public var asClosedRange: ClosedRange<Date> { lowerBound...upperBound }
    /// Inclusive: ranges that only touch (one ends exactly where the other starts) overlap.
    /// Used by the tap-free collision check, where a shared boundary counts as a clash.
    public func overlaps(_ other: DateRange) -> Bool {
        lowerBound <= other.upperBound && other.lowerBound <= upperBound
    }
    /// Positive-duration: true only when the ranges share some time. Touching ranges and
    /// zero-duration ranges never intersect (D10). Used for heatmap counting and lock promotion.
    /// Same as `lower < other.upper && other.lower < upper` for non-empty ranges, but also
    /// rejects an instant inside a range.
    public func intersects(_ other: DateRange) -> Bool {
        max(lowerBound, other.lowerBound) < min(upperBound, other.upperBound)
    }
}
