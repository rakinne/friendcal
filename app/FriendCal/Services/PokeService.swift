import Foundation

/// Poke rate limit: 1 per (from,to,proposal) per 24h; mute per user
actor PokeService {
    struct Key: Hashable { var from: UUID; var to: UUID; var proposalID: UUID }
    private var lastSent: [Key: Date] = [:]
    private var mutedUsers: Set<UUID> = []

    func canPoke(from: UUID, to: UUID, proposalID: UUID) -> Bool {
        if mutedUsers.contains(to) { return false }
        let k = Key(from: from, to: to, proposalID: proposalID)
        guard let last = lastSent[k] else { return true }
        return Date().timeIntervalSince(last) >= 24*3600
    }

    func recordPokeSafe(from: UUID, to: UUID, proposalID: UUID) -> Poke? {
        let k = Key(from: from, to: to, proposalID: proposalID)
        if let last = lastSent[k], Date().timeIntervalSince(last) < 24*3600 { return nil }
        if mutedUsers.contains(to) { return nil }
        let poke = Poke(from: from, to: to, proposalID: proposalID)
        lastSent[k] = Date()
        return poke
    }

    func mute(_ userID: UUID) { mutedUsers.insert(userID) }
    func unmute(_ userID: UUID) { mutedUsers.remove(userID) }
}
