import Foundation

public enum AvailabilityState: String, Codable {
    case free
    case softHold  // tapped free in a Proposal, pre-commit but not yet Busy — prevents 10am double-book without over-blocking
    case busy      // hard hold after lock or manual Busy
}

public struct AvailabilitySlot: Identifiable, Codable, Equatable {
    public var id: UUID
    public var userID: UUID
    public var range: DateRange
    public var sourceProposalID: UUID? // nil = manual / global profile entry
    public var state: AvailabilityState
    public var createdAt: Date
    public var expiresAt: Date? // SoftHold expiry (e.g. lock deadline) — P0 requirement

    public init(id: UUID = UUID(), userID: UUID, range: DateRange, sourceProposalID: UUID?, state: AvailabilityState, createdAt: Date = Date(), expiresAt: Date? = nil) {
        self.id = id
        self.userID = userID
        self.range = range
        self.sourceProposalID = sourceProposalID
        self.state = state
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return Date() > exp
    }
}

// Heatmap row: one candidate date's convergence
public struct HeatmapRow: Identifiable {
    public var id: Date { date }
    public let date: Date
    public let freeCount: Int
    public let totalRecipients: Int
    public init(date: Date, freeCount: Int, totalRecipients: Int) {
        self.date = date
        self.freeCount = freeCount
        self.totalRecipients = totalRecipients
    }
    public var coverage: Double { totalRecipients == 0 ? 0 : Double(freeCount)/Double(totalRecipients) }
    public var level: Level {
        switch coverage {
        case 1.0: return .green
        case 0.5..<1.0: return .yellow
        default: return .red
        }
    }
    public enum Level { case green, yellow, red }
}
