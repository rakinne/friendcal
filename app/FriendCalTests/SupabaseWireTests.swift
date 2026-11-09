import Supabase
import XCTest
@testable import FriendCalCore

/// The parts of the network store that are pure: Postgres range text and the error contract.
final class SupabaseWireTests: XCTestCase {
    private let nov14at18 = Date(timeIntervalSince1970: 1_794_679_200)

    func testParsesPostgresRangeOutput() throws {
        let r = try XCTUnwrap(RangeText.parse(#"["2026-11-14 18:00:00+00","2026-11-14 20:00:00+00")"#))
        XCTAssertEqual(r.lowerBound, nov14at18)
        XCTAssertEqual(r.upperBound, nov14at18.addingTimeInterval(7200))
    }

    func testParsesFractionalSecondsAndOffsetsWithMinutes() throws {
        let r = try XCTUnwrap(RangeText.parse(#"["2026-11-14 13:00:00.5-05","2026-11-14 15:00:00+05:30")"#))
        XCTAssertEqual(r.lowerBound, nov14at18.addingTimeInterval(0.5))
        // 15:00 at +05:30 is 09:30Z.
        XCTAssertEqual(r.upperBound, nov14at18.addingTimeInterval(-8.5 * 3600))
    }

    func testRejectsGarbage() {
        XCTAssertNil(RangeText.parse("empty"))
        XCTAssertNil(RangeText.parse("[x,y)"))
    }

    func testFormatRoundTrips() throws {
        let range = DateRange(lower: nov14at18, upper: nov14at18.addingTimeInterval(5400))
        XCTAssertEqual(RangeText.parse(RangeText.format(range)), range)
    }

    func testPostgrestRefusalKeepsSQLStateAndHint() {
        let e = PostgrestError(hint: "FC_QUORUM", code: "22023", message: "need 80 percent free")
        XCTAssertEqual(SupabaseProposalStore.map(e) as? ProposalStoreError,
                       .server(code: "22023", message: "need 80 percent free", hint: "FC_QUORUM"))
        // ...and the sentence the user sees comes from the hint, exactly as with the in-memory store.
        XCTAssertEqual(UserFacingError.map(SupabaseProposalStore.map(e), action: .lock).message,
                       "Not enough friends are free anymore. Pick another time.")
    }

    func testNetworkFailuresAreNetworkErrors() {
        XCTAssertEqual(SupabaseProposalStore.map(URLError(.notConnectedToInternet)) as? ProposalStoreError,
                       .network(URLError(.notConnectedToInternet).localizedDescription))
    }

    func testCancellationPassesThrough() {
        XCTAssertTrue(SupabaseProposalStore.map(CancellationError()) is CancellationError)
    }
}
