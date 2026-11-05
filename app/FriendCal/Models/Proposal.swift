import Foundation

enum DistributionMode: String, Codable {
    case separately // Instagram-like Send Separately (N 1:1 threads)
    case newGroup    // Send in New Group (1 group thread)
}

struct Distribution: Codable, Equatable {
    var mode: DistributionMode
    var recipientIDs: [UUID]
}

enum ProposalStatus: String, Codable {
    case drafting
    case requesting // Request for Times fired
    case locked
    case cancelled
}

struct Proposal: Identifiable, Codable {
    var id: UUID
    var title: String // e.g. "Friendsgivemas"
    var window: ClosedRange<Date> // e.g. Nov 20 - Dec 19 from screenshots
    var createdBy: UUID
    var distribution: Distribution
    var status: ProposalStatus = .requesting
    var createdAt: Date = Date()
    var lockedDate: Date? // final chosen date (e.g. Nov 21st)
    var venueHint: String? // location optional, e.g. host's place
}

extension Proposal {
    static var friendsgivemasPreview: Proposal {
        Proposal(
            id: UUID(),
            title: "Friendsgivemas",
            window: Date.now...Calendar.current.date(byAdding: .day, value: 45, to: .now)!,
            createdBy: UUID(),
            distribution: Distribution(mode: .newGroup, recipientIDs: []),
            status: .requesting
        )
    }
}
