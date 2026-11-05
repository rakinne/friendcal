import Foundation

struct TicketTap: Identifiable, Codable {
    var id: UUID = UUID()
    var createdBy: UUID
    var sourceURL: URL // NBA game, indie concert, pop-up
    var title: String
    var date: Date?
    var venue: String?
    var tagAlongCount: Int = 0
    var tagAlongUserIDs: [UUID] = []
    var createdAt: Date = Date()
    // Deep-link candidates derived from URL (Ticketmaster, Posh, Partiful)
    var purchaseLinks: [PurchaseLink] = []
    struct PurchaseLink: Codable, Equatable {
        var label: String
        var url: URL
    }
}
