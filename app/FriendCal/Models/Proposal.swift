import Foundation

public enum DistributionMode: String, Codable {
    case separately // Instagram-like Send Separately (N 1:1 threads)
    case newGroup    // Send in New Group (1 group thread)
}

public struct Distribution: Codable, Equatable {
    public var mode: DistributionMode
    public var recipientIDs: [UUID]
    public init(mode: DistributionMode, recipientIDs: [UUID]) {
        self.mode = mode
        self.recipientIDs = recipientIDs
    }
}

public enum ProposalStatus: String, Codable {
    case drafting
    case requesting // Request for Times fired
    case locked
    case cancelled
}

public struct Proposal: Identifiable, Codable {
    public var id: UUID
    public var title: String // e.g. "Friendsgivemas"
    public var window: DateRange // e.g. Nov 20 - Dec 19 from screenshots
    public var createdBy: UUID
    public var distribution: Distribution
    public var status: ProposalStatus
    public var createdAt: Date
    public var lockedDate: Date? // final chosen date (e.g. Nov 21st): the locked common window's start
    public var lockedEnd: Date? // the locked common window's end (D12); persisted as proposals.locked_end
    public var venueHint: String? // location optional, e.g. host's place

    public init(id: UUID, title: String, window: DateRange, createdBy: UUID, distribution: Distribution, status: ProposalStatus = .requesting, createdAt: Date = Date(), lockedDate: Date? = nil, lockedEnd: Date? = nil, venueHint: String? = nil) {
        self.id = id
        self.title = title
        self.window = window
        self.createdBy = createdBy
        self.distribution = distribution
        self.status = status
        self.createdAt = createdAt
        self.lockedDate = lockedDate
        self.lockedEnd = lockedEnd
        self.venueHint = venueHint
    }
}

extension Proposal {
    public static var friendsgivemasPreview: Proposal {
        Proposal(
            id: UUID(),
            title: "Friendsgivemas",
            window: DateRange(Date.now...Calendar.current.date(byAdding: .day, value: 45, to: .now)!),
            createdBy: UUID(),
            distribution: Distribution(mode: .newGroup, recipientIDs: []),
            status: .requesting
        )
    }
}
