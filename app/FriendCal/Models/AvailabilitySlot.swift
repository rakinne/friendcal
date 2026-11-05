import Foundation

enum AvailabilityState: String, Codable {
    case free
    case softHold  // tapped free in a Proposal, pre-commit but not yet Busy — prevents 10am double-book without over-blocking
    case busy      // hard hold after lock or manual Busy
}

struct AvailabilitySlot: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var userID: UUID
    var range: ClosedRange<Date>
    var sourceProposalID: UUID? // nil = manual / global profile entry
    var state: AvailabilityState
    var createdAt: Date = Date()
    var expiresAt: Date? // SoftHold expiry (e.g. lock deadline) — P0 requirement

    var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return Date() > exp
    }
}

// Heatmap row: one candidate date's convergence
struct HeatmapRow: Identifiable {
    var id: Date { date }
    let date: Date
    let freeCount: Int
    let totalRecipients: Int
    var coverage: Double { totalRecipients == 0 ? 0 : Double(freeCount)/Double(totalRecipients) }
    var level: Level {
        switch coverage {
        case 1.0: return .green
        case 0.5..<1.0: return .yellow
        default: return .red
        }
    }
    enum Level { case green, yellow, red }
}
