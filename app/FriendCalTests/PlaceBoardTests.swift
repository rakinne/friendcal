import XCTest
@testable import FriendCalCore

/// The winner rule and everything derived from it (R7), against the same six cases the SQL runs.
///
/// Cards. Each test says what it protects, what wrong result it rejects, and what green does not prove.
final class PlaceBoardTests: XCTestCase {
    // MARK: shared fixture

    private struct Cases: Decodable {
        struct Case: Decodable {
            struct P: Decodable { let key: String; let id: UUID; let createdAt: Date; let vetoed: Bool }
            let name: String
            let places: [P]
            let votes: [String: Int]
            let winner: String?
        }
        let cases: [Case]
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadCases() throws -> [Cases.Case] {
        let url = Self.repoRoot.appendingPathComponent("supabase/tests/fixtures/place_winner_cases.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Cases.self, from: Data(contentsOf: url)).cases
    }

    private let plan = UUID()
    private let host = UUID()
    private func t(_ minute: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(minute) * 60) }

    private func place(_ name: String = "P", by: UUID? = nil, at minute: Int = 0, id: UUID = UUID(), vetoed: Bool = false,
                       lat: Double = 30.0, lon: Double = -97.0, ref: String? = nil) -> Place {
        Place(id: id, proposalID: plan, suggestedBy: by ?? UUID(), name: name, latitude: lat, longitude: lon, mapRef: ref,
              vetoedAt: vetoed ? t(minute) : nil, createdAt: t(minute))
    }
    private func vote(_ p: Place, by: UUID = UUID(), at minute: Int = 0) -> PlaceVote {
        PlaceVote(proposalID: plan, voterID: by, placeID: p.id, createdAt: t(minute))
    }

    // MARK: winner cases

    /// protects=the Swift winner equals the SQL winner for the six shared cases, and the lock
    /// projection agrees with it; fails_when=any case differs, id ties compare differently from
    /// Postgres, or a vetoed place that still holds a vote wins; no_claim=the SQL side, which reads the
    /// same file in supabase/tests/places_test.sql; voters are generated, only the counts come from the file.
    func testSharedWinnerCases() throws {
        let cases = try loadCases()
        XCTAssertEqual(cases.map(\.name).count, 6, "the shared file holds P1 to P6")
        for c in cases {
            let places = c.places.map { p in
                Place(id: p.id, proposalID: plan, suggestedBy: host, name: "Place \(p.key)", latitude: 30, longitude: -97,
                      vetoedAt: p.vetoed ? p.createdAt : nil, createdAt: p.createdAt)
            }
            var votes: [PlaceVote] = []
            for (key, count) in c.votes {
                guard let id = c.places.first(where: { $0.key == key })?.id else { return XCTFail("\(c.name): unknown key \(key)") }
                for _ in 0..<count { votes.append(PlaceVote(proposalID: plan, voterID: UUID(), placeID: id, createdAt: t(0))) }
            }
            let expected = c.winner.flatMap { key in c.places.first { $0.key == key }?.id }
            XCTAssertEqual(PlaceBoard.winner(places: places, votes: votes), expected, c.name)
            switch PlaceBoard.projection(places: places, votes: votes) {
            case .winner(let p, _): XCTAssertEqual(p.id, expected, c.name)
            case .tied(let p, _, _): XCTAssertEqual(p.id, expected, c.name)
            case .none: XCTAssertNil(expected, c.name)
            }
        }
    }

    /// protects=ordering is votes, then earliest, then lowest id, whatever order the input arrives in;
    /// fails_when=ranking follows array or dictionary order, or ties on time fall to insertion order;
    /// no_claim=how the UI shows ties (#13).
    func testRankingIsVotesThenEarliestThenId() {
        let a = place("A", at: 5), b = place("B", at: 1), c = place("C", at: 1)
        let low = c.id.uuidString < b.id.uuidString ? c : b      // the lower id wins the time tie
        let high = low.id == b.id ? c : b
        let votes = [vote(a, at: 1), vote(a, at: 2), vote(b, at: 3), vote(c, at: 4)]
        let board = PlaceBoard.make(places: [c, b, a], votes: votes, viewer: nil)
        XCTAssertEqual(board.active.map(\.id), [a.id, low.id, high.id])
        XCTAssertEqual(board.leaderID, a.id)
        XCTAssertTrue(board.tiedWith.isEmpty)
        let reversed = PlaceBoard.make(places: [a, b, c], votes: votes.reversed(), viewer: nil)
        XCTAssertEqual(reversed.active.map(\.id), board.active.map(\.id), "input order must not matter")
    }

    /// protects=the id tie-break uses Postgres uuid byte order; fails_when=ids compare by Swift's
    /// uppercase string differently from Postgres; no_claim=none beyond protects.
    func testIdTieBreakMatchesUUIDByteOrder() {
        let lowID = UUID(uuidString: "0aaaaaaa-0000-0000-0000-000000000000")!
        let highID = UUID(uuidString: "ffffffff-0000-0000-0000-000000000000")!
        let low = place("Low", at: 0, id: lowID), high = place("High", at: 0, id: highID)
        XCTAssertEqual(PlaceBoard.winner(places: [high, low], votes: [vote(high), vote(low)]), lowID)
    }

    /// protects=isMine, iVoted, voters order and myVotePlaceID are the viewer's view; fails_when=the
    /// viewer's own place or vote is attributed to someone else, or voters are not oldest first;
    /// no_claim=names, which the session resolves.
    func testViewerFieldsAndVoterOrder() {
        let me = UUID(), early = UUID(), late = UUID()
        let mine = place("Mine", by: me, at: 0), other = place("Other", at: 1)
        let board = PlaceBoard.make(places: [mine, other],
                                    votes: [vote(other, by: late, at: 9), vote(other, by: early, at: 2), vote(other, by: me, at: 5)], viewer: me)
        let row = board.active.first { $0.id == other.id }!
        XCTAssertEqual(row.voters, [early, me, late])
        XCTAssertTrue(row.iVoted)
        XCTAssertFalse(row.isMine)
        XCTAssertTrue(board.active.first { $0.id == mine.id }!.isMine)
        XCTAssertEqual(board.myVotePlaceID, other.id)
        XCTAssertNil(PlaceBoard.make(places: [mine, other], votes: [], viewer: me).myVotePlaceID)
    }

    /// protects=vetoed places sort last by time then id and show no voters, and a vote for a vetoed or
    /// unknown place counts for nothing; fails_when=a vetoed place leads, or an orphan vote moves the
    /// leader; no_claim=none beyond protects.
    func testVetoedRowsAndOrphanVotes() {
        let live = place("Live", at: 3), gone = place("Gone", at: 1, vetoed: true), later = place("Later", at: 2, vetoed: true)
        let orphan = PlaceVote(proposalID: plan, voterID: UUID(), placeID: UUID(), createdAt: t(0))
        let board = PlaceBoard.make(places: [later, live, gone], votes: [vote(gone), vote(gone), orphan, vote(live)], viewer: nil)
        XCTAssertEqual(board.active.map(\.id), [live.id])
        XCTAssertEqual(board.vetoed.map(\.id), [gone.id, later.id])
        XCTAssertTrue(board.vetoed.allSatisfy { $0.voters.isEmpty })
        XCTAssertEqual(board.leaderID, live.id)
    }

    /// protects=tiedWith lists every active place level with the leader at the top count and is empty
    /// with no votes or no tie; fails_when=a lower count is listed, the leader lists itself, or an
    /// unvoted board reports a tie; no_claim=the TIED badge's look (#13).
    func testTiedWith() {
        let a = place("A", at: 0), b = place("B", at: 1), c = place("C", at: 2), d = place("D", at: 3)
        let three = PlaceBoard.make(places: [a, b, c, d], votes: [vote(a), vote(b), vote(c), vote(d), vote(d)], viewer: nil)
        XCTAssertEqual(three.leaderID, d.id)
        XCTAssertTrue(three.tiedWith.isEmpty)
        let tie = PlaceBoard.make(places: [a, b, c], votes: [vote(a), vote(b), vote(c), vote(c, at: 1)], viewer: nil)
        XCTAssertEqual(tie.leaderID, c.id)
        let level = PlaceBoard.make(places: [a, b, c], votes: [vote(a), vote(b)], viewer: nil)
        XCTAssertEqual(level.leaderID, a.id)
        XCTAssertEqual(level.tiedWith, [b.id], "c has no votes and is not tied")
        let none = PlaceBoard.make(places: [a, b], votes: [], viewer: nil)
        XCTAssertNil(none.leaderID)
        XCTAssertTrue(none.tiedWith.isEmpty)
    }

    /// protects=the lock sheet previews winner, tie (earliest suggested wins) or none exactly as the
    /// server will freeze it; fails_when=the preview names a different place than R7 picks or hides a
    /// tie; no_claim=the stored winner, which #11 covers.
    func testProjection() {
        let a = place("A", at: 0), b = place("B", at: 1)
        XCTAssertEqual(PlaceBoard.projection(places: [a, b], votes: []), .none)
        XCTAssertEqual(PlaceBoard.projection(places: [a, b], votes: [vote(a), vote(a, at: 1)]), .winner(a, votes: 2))
        XCTAssertEqual(PlaceBoard.projection(places: [b, a], votes: [vote(a), vote(b)]), .tied(winner: a, others: [b], votes: 1))
    }

    // MARK: duplicates

    /// protects=an active match wins over a vetoed one, the earliest among several wins, and no match
    /// is nil; fails_when=a vetoed copy hides an active one, or insertion order picks; no_claim=places
    /// more than 110 m apart or spelled differently.
    func testExistingPrefersActiveThenEarliest() {
        let vetoed = place("Dup", at: 0, vetoed: true), second = place("Dup", at: 6), first = place("dup", at: 5)
        let new = NewPlace(name: "  DUP ", latitude: 30.0, longitude: -97.0)
        XCTAssertEqual(PlaceBoard.existing(matching: new, in: [vetoed, second, first])?.id, first.id)
        XCTAssertEqual(PlaceBoard.existing(matching: new, in: [vetoed])?.id, vetoed.id, "only a vetoed match: reported as vetoed")
        XCTAssertNil(PlaceBoard.existing(matching: NewPlace(name: "Other", latitude: 30, longitude: -97), in: [first]))
    }

    /// protects=the same map reference is the same place whatever the name; fails_when=the reference
    /// is ignored or a nil reference matches another nil; no_claim=none beyond protects.
    func testExistingMatchesByMapRef() {
        let known = place("Cafe Lola", lat: 30.0, lon: -97.0, ref: "M1")
        XCTAssertEqual(PlaceBoard.existing(matching: NewPlace(name: "Entirely different", latitude: 10, longitude: 10, mapRef: "M1"), in: [known])?.id, known.id)
        XCTAssertNil(PlaceBoard.existing(matching: NewPlace(name: "Entirely different", latitude: 10, longitude: 10, mapRef: nil), in: [known]))
        XCTAssertNil(PlaceBoard.existing(matching: NewPlace(name: "Entirely different", latitude: 10, longitude: 10, mapRef: "  "), in: [known]))
    }

    /// protects=duplicates merge only strictly inside 0.001 degrees on BOTH axes; exactly 0.001 is a
    /// new place, as in SQL; fails_when=the boundary is inclusive, or one axis is ignored;
    /// no_claim=floating-point behavior away from the 0.0 / 0.001 pair, which is chosen so the
    /// difference is the literal itself.
    func testDuplicateBoundaryIsStrict() {
        let edge = place("Edge", lat: 0.0, lon: 0.0)
        func match(_ lat: Double, _ lon: Double) -> Bool {
            PlaceBoard.existing(matching: NewPlace(name: "Edge", latitude: lat, longitude: lon), in: [edge]) != nil
        }
        XCTAssertTrue(match(0.0009, 0.0))
        XCTAssertFalse(match(0.001, 0.0), "exactly 0.001 on latitude is a new place")
        XCTAssertFalse(match(0.0, 0.001), "exactly 0.001 on longitude is a new place")
        XCTAssertFalse(match(0.0005, 0.002), "one axis outside is enough")
    }

    // MARK: suggest availability

    private func proposal(area: Bool = true, status: ProposalStatus = .requesting) -> Proposal {
        Proposal(id: plan, title: "Brunch", window: DateRange(lower: t(0), upper: t(60)), createdBy: host,
                 distribution: Distribution(mode: .newGroup, recipientIDs: [host]), status: status,
                 area: area ? SearchArea(name: "Austin, TX", latitude: 30.2672, longitude: -97.7431) : nil, expectedCount: 4)
    }

    /// protects=each reason fires for its condition, in the documented precedence, and `available`
    /// otherwise; fails_when=Suggest is offered when the server would refuse, or the wrong reason wins;
    /// no_claim=the muted line's copy (#14).
    func testSuggestAvailabilityPrecedence() {
        let me = host
        func avail(_ p: Proposal?, _ places: [Place], viewer: UUID? = nil) -> SuggestAvailability {
            PlaceBoard.suggestAvailability(proposal: p, places: places, viewer: viewer ?? me)
        }
        XCTAssertEqual(avail(proposal(), [], viewer: UUID()), .notMember)
        XCTAssertEqual(avail(nil, []), .notMember)
        XCTAssertEqual(avail(proposal(area: false, status: .locked), []), .locked, "locked outranks no city")
        XCTAssertEqual(avail(proposal(status: .cancelled), []), .locked)
        XCTAssertEqual(avail(proposal(area: false), []), .noCity)
        let mine = [place("1", by: me), place("2", by: me)]
        let others = (0..<8).map { place("o\($0)", at: $0 + 1) }
        XCTAssertEqual(avail(proposal(area: false), mine), .noCity, "no city outranks the personal cap")
        XCTAssertEqual(avail(proposal(), mine + others), .personalCap, "the personal cap outranks a full plan")
        XCTAssertEqual(avail(proposal(), [place("1", by: me)] + others + [place("x")]), .planFull, "10 active, viewer has 1")
        XCTAssertEqual(avail(proposal(), [place("1", by: me), place("2", by: me, vetoed: true)]), .available, "a vetoed place does not count")
        XCTAssertEqual(avail(proposal(), []), .available)
    }

    // MARK: pinned to the SQL

    /// protects=the personal cap, plan cap and duplicate radius in Swift equal the literals in
    /// supabase/places.sql; fails_when=either side changes alone; no_claim=the SQL behaves as written,
    /// which places_test.sql runs.
    func testCapsAndRadiusArePinnedToPlacesSQL() throws {
        let sql = try String(contentsOf: Self.repoRoot.appendingPathComponent("supabase/places.sql"), encoding: .utf8)
        func constant(_ name: String) throws -> Int {
            let pattern = "\(name)\\s+constant\\s+int\\s*:=\\s*(\\d+)"
            let match = try XCTUnwrap(sql.range(of: pattern, options: .regularExpression), "places.sql no longer declares \(name)")
            return try XCTUnwrap(Int(sql[match].split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ;")) } ?? ""))
        }
        XCTAssertEqual(try constant("c_per_person"), PlaceBoard.perPersonLimit)
        XCTAssertEqual(try constant("c_per_plan"), PlaceBoard.planLimit)
        XCTAssertTrue(sql.contains("< 0.001"), "places.sql no longer uses the strict 0.001 degree comparison")
        XCTAssertFalse(sql.contains("<= 0.001"), "the duplicate boundary must stay strict")
        XCTAssertEqual(PlaceBoard.duplicateDegrees, 0.001)
    }
}
