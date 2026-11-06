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
