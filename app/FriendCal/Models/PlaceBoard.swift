import Foundation

/// What locking now would freeze, for the lock sheet (design PL-11). Uses the same ordering and the
/// same at-least-one-vote rule as the winner, so the preview names what the server will store.
public enum LockProjection: Equatable, Sendable {
    case winner(Place, votes: Int)
    /// The earliest suggested wins a tie (R7); `others` are the places it is tied with.
    case tied(winner: Place, others: [Place], votes: Int)
    /// No non-vetoed place has a vote.
    case none
}

/// Why Suggest is, or is not, offered. When more than one reason applies the first of this order wins:
/// notMember, locked, noCity, personalCap, planFull.
public enum SuggestAvailability: Equatable, Sendable {
    case available, noCity, personalCap, planFull, locked, notMember
}

/// The places on one plan as a viewer sees them, and the one Swift implementation of R7.
///
/// The server's rule is `friendcal_place_winner` in supabase/places.sql. The six shared cases live in
/// ONE file, supabase/tests/fixtures/place_winner_cases.json, which both test suites read, so there
/// is no copy to keep in sync by hand. The caps and the duplicate radius below are pinned to
/// places.sql by a test that reads the SQL.
public struct PlaceBoard: Equatable {
    public static let perPersonLimit = 2
    public static let planLimit = 10
    /// Two places with the same name are the same place when both coordinates are STRICTLY less than
    /// this many degrees apart (about 110 m).
    public static let duplicateDegrees = 0.001

    public struct Row: Identifiable, Equatable {
        public var place: Place
        /// Oldest vote first, ties by id. Empty for a vetoed place: a veto clears its votes.
        public var voters: [UUID]
        public var voteCount: Int { voters.count }
        /// Suggested by the viewer.
        public var isMine: Bool
        public var iVoted: Bool
        public var id: UUID { place.id }
    }

    /// Votes descending, then createdAt ascending, then id ascending.
    public var active: [Row]
    /// createdAt ascending, then id ascending.
    public var vetoed: [Row]
    /// Who would win if the plan locked now: this board's `winner`. A preview while the plan is
    /// requesting; after lock the authoritative winner is the stored `lockedPlaceID`, never this.
    public var leaderID: UUID?
    /// Other active places tied with the leader at the top count; empty with no tie or no votes.
    public var tiedWith: [UUID]
    public var myVotePlaceID: UUID?

    public static func make(places: [Place], votes: [PlaceVote], viewer: UUID?) -> PlaceBoard {
        let liveIDs = Set(places.filter { !$0.isVetoed }.map(\.id))
        var byPlace: [UUID: [PlaceVote]] = [:]
        for vote in votes where liveIDs.contains(vote.placeID) { byPlace[vote.placeID, default: []].append(vote) }

        func row(_ place: Place) -> Row {
            let ordered = (byPlace[place.id] ?? []).sorted { (lhs: PlaceVote, rhs: PlaceVote) in
                (lhs.createdAt, key(lhs.voterID)) < (rhs.createdAt, key(rhs.voterID))
            }
            var seen = Set<UUID>()
            let voters = ordered.map(\.voterID).filter { seen.insert($0).inserted }
            return Row(place: place, voters: voters, isMine: place.suggestedBy == viewer,
                       iVoted: viewer.map(voters.contains) ?? false)
        }

        let active = places.filter { !$0.isVetoed }.map(row).sorted(by: ranksBefore)
        let vetoed = places.filter(\.isVetoed).map(row).sorted { (lhs: Row, rhs: Row) in
            (lhs.place.createdAt, key(lhs.place.id)) < (rhs.place.createdAt, key(rhs.place.id))
        }
        let leader = active.first.flatMap { $0.voteCount >= 1 ? $0 : nil }
        let tied = leader.map { top in active.dropFirst().filter { $0.voteCount == top.voteCount }.map(\.id) } ?? []
        let mine = viewer.flatMap { v in votes.first { $0.voterID == v && liveIDs.contains($0.placeID) }?.placeID }
        return PlaceBoard(active: active, vetoed: vetoed, leaderID: leader?.id, tiedWith: tied, myVotePlaceID: mine)
    }

    /// R7: non-vetoed, at least one vote, most votes, then earliest createdAt, then lowest id.
    /// Votes that point at a vetoed or unknown place are ignored.
    public static func winner(places: [Place], votes: [PlaceVote]) -> UUID? {
        make(places: places, votes: votes, viewer: nil).leaderID
    }

    /// The duplicate rule shared by the store and the search sheet: an active place with the same
    /// non-nil mapRef, or the same lowercased name with both coordinates strictly less than
    /// `duplicateDegrees` apart. Active matches win over vetoed ones; among several, the earliest
    /// createdAt, then the lowest id. A vetoed result means "the host passed on this".
    public static func existing(matching place: NewPlace, in places: [Place]) -> Place? {
        let name = PlaceText.trim(place.name).lowercased()
        let ref = PlaceText.trimmedOrNil(place.mapRef)
        func matches(_ other: Place) -> Bool {
            if let ref, other.mapRef == ref { return true }
            // Scalar for scalar, like Postgres `lower(a) = lower(b)`: Swift's `==` on String would also
            // treat canonically equivalent spellings ("Café" vs "Cafe\u{301}") as the same place.
            return other.name.lowercased().unicodeScalars.elementsEqual(name.unicodeScalars)
                && abs(other.latitude - place.latitude) < duplicateDegrees
                && abs(other.longitude - place.longitude) < duplicateDegrees
        }
        func earliest(_ list: [Place]) -> Place? {
            list.min { (lhs: Place, rhs: Place) in (lhs.createdAt, key(lhs.id)) < (rhs.createdAt, key(rhs.id)) }
        }
        return earliest(places.filter { !$0.isVetoed && matches($0) }) ?? earliest(places.filter { $0.isVetoed && matches($0) })
    }

    /// What locking now would freeze.
    public static func projection(places: [Place], votes: [PlaceVote]) -> LockProjection {
        let board = make(places: places, votes: votes, viewer: nil)
        guard let leaderID = board.leaderID, let top = board.active.first(where: { $0.id == leaderID }) else { return .none }
        if board.tiedWith.isEmpty { return .winner(top.place, votes: top.voteCount) }
        let others = board.active.filter { board.tiedWith.contains($0.id) }.map(\.place)
        return .tied(winner: top.place, others: others, votes: top.voteCount)
    }

    /// Why Suggest is or is not offered to `viewer`, in the precedence documented on the enum.
    public static func suggestAvailability(proposal: Proposal?, places: [Place], viewer: UUID?) -> SuggestAvailability {
        guard let proposal, let viewer, proposal.isReadable(by: viewer) else { return .notMember }
        if proposal.status != .requesting { return .locked }
        if proposal.area == nil { return .noCity }
        let activeMine = places.filter { !$0.isVetoed && $0.suggestedBy == viewer }.count
        if activeMine >= perPersonLimit { return .personalCap }
        if places.filter({ !$0.isVetoed }).count >= planLimit { return .planFull }
        return .available
    }

    // MARK: ordering

    /// Id order compares the lowercased uuid string, which matches Postgres byte order for `uuid`.
    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func ranksBefore(_ lhs: Row, _ rhs: Row) -> Bool {
        if lhs.voteCount != rhs.voteCount { return lhs.voteCount > rhs.voteCount }
        return (lhs.place.createdAt, key(lhs.place.id)) < (rhs.place.createdAt, key(rhs.place.id))
    }
}
