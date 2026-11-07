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

public struct Proposal: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String // e.g. "Brunch"; never carries the "?" the app appends while requesting (design 2.1A)
    public var window: DateRange // e.g. Nov 20 - Dec 19 from screenshots
    public var createdBy: UUID
    public var distribution: Distribution
    public var status: ProposalStatus
    public var createdAt: Date
    public var lockedDate: Date? // final chosen date (e.g. Nov 21st): the locked common window's start
    public var lockedEnd: Date? // the locked common window's end (D12); persisted as proposals.locked_end
    public var venueHint: String? // location optional, e.g. host's place
    /// How many people the creator expects, counting themselves (D13, design 3.3A). The quorum base
    /// is max(expectedCount, joinedCount) on both client and server; persisted as proposals.expected_count.
    public var expectedCount: Int
    /// Recipients the lock promoted to Busy (C1): set by lock_proposal in the lock transaction and
    /// read from the proposal row, never from busy_blocks (X1). Persisted as locked_attendee_ids.
    public var lockedAttendeeIDs: [UUID]
    /// Recipients who opened the link after the lock (viewers, delta O1); also in recipientIDs.
    public var postLockRecipientIDs: [UUID]
    public var lockedAt: Date?

    public init(id: UUID, title: String, window: DateRange, createdBy: UUID, distribution: Distribution, status: ProposalStatus = .requesting, createdAt: Date = Date(), lockedDate: Date? = nil, lockedEnd: Date? = nil, venueHint: String? = nil, expectedCount: Int = 1, lockedAttendeeIDs: [UUID] = [], postLockRecipientIDs: [UUID] = [], lockedAt: Date? = nil) {
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
        self.expectedCount = expectedCount
        self.lockedAttendeeIDs = lockedAttendeeIDs
        self.postLockRecipientIDs = postLockRecipientIDs
        self.lockedAt = lockedAt
    }
}

extension Proposal {
    /// Distinct recipients in first-seen order (D5).
    public var joinedIDs: [UUID] { HeatmapBuilder.distinct(distribution.recipientIDs) }
    public var joinedCount: Int { joinedIDs.count }
    /// The quorum base (D13): the crew the creator expects, or everyone who joined if more did.
    public var headcount: Int { max(expectedCount, joinedCount) }
    public var isLocked: Bool { status == .locked }
    /// Both ends of the locked common window (D12); nil until locked.
    public var lockedWindow: DateRange? {
        guard let start = lockedDate, let end = lockedEnd else { return nil }
        return DateRange(lower: start, upper: end)
    }

    public func isCreator(_ userID: UUID?) -> Bool { userID == createdBy }
    public func isRecipient(_ userID: UUID?) -> Bool { userID.map(distribution.recipientIDs.contains) ?? false }
    public func isAttendee(_ userID: UUID?) -> Bool { userID.map(lockedAttendeeIDs.contains) ?? false }

    /// The title as the app shows it (design 2.1A): "Brunch?" while requesting, "Brunch" once locked.
    public var displayTitle: String { Self.displayTitle(title, isLocked: isLocked) }

    public static func displayTitle(_ title: String, isLocked: Bool) -> String {
        isLocked ? title : "\(title)?"
    }
}
