import XCTest
@testable import FriendCalCore

/// Every failure's plain-language sentence (design 2.3A, delta C3/O3).
final class UserFacingErrorTests: XCTestCase {
    private func server(_ code: String, _ hint: String? = nil) -> Error {
        ProposalStoreError.server(code: code, message: "raw server text", hint: hint)
    }

    /// protects=each hint, SQLSTATE, client lock error and network failure maps to its sentence, with
    /// the raw text kept under details and the hint winning over an overloaded 22023 (O3);
    /// fails_when=a code maps to the wrong sentence, details are dropped, or an unknown code is not
    /// generic; no_claim=live server error shapes (fixture errors stand in).
    func testMapTable() {
        let rows: [(Error, UserFacingError.Action, String)] = [
            (server("22023", "FC_QUORUM"), .lock, "Not enough friends are free anymore. Pick another time."),
            (server("22023"), .lock, "Not enough friends are free anymore. Pick another time."),
            (server("22023", "FC_DATES_FROZEN"), .edit, "Can't change the dates once friends have marked times."),
            (server("22023", "FC_WINDOW"), .lock, "That time doesn't fit inside the plan."),
            (server("22023", "FC_NO_RECIPIENTS"), .lock, "No one has joined yet."),
            (server("40001", "FC_CHANGED"), .lock, "Availability changed while locking. Try again."),
            (server("40001"), .lock, "Availability changed while locking. Try again."),
            (server("55000", "FC_LOCKED"), .lock, "This plan is already locked."),
            (server("55000"), .mark, "This plan is already locked."),
            (server("42501", "FC_NOT_CREATOR"), .lock, "Only Sam can lock this plan."),
            (server("42501"), .lock, "Only Sam can lock this plan."),
            (server("42501", "FC_NOT_CREATOR"), .edit, "Only Sam can edit this plan."),
            (server("42501"), .edit, "Only Sam can edit this plan."),
            (server("42501", "FC_NOT_OWNER"), .mark, "That hold isn't yours."),
            (server("55000", "FC_CLOSED"), .join, "This plan is closed."),
            (server("42501", "FC_NOT_MEMBER"), .mark, "Join this plan before marking times."),
            (server("XX000"), .lock, "Couldn't lock. Try again."),
            (server("XX000"), .mark, "Couldn't save your availability. Retry."),
            (server("XX000"), .create, "Couldn't create the plan. Retry."),
            (server("XX000"), .edit, "Couldn't save your changes. Retry."),
            (ProposalStoreError.network("offline"), .mark, "Couldn't save your availability. Retry."),
            (ProposalStoreError.network("offline"), .join, "Couldn't open this invite."),
            (ProposalStoreError.network("offline"), .load, "Couldn't open this invite."),
            (URLError(.notConnectedToInternet), .create, "Couldn't create the plan. Retry."),
            (ProposalStoreError.notFound(UUID()), .load, "This plan is gone."),
            (ProposalStoreError.heldElsewhere, .mark, "You already hold that time for another plan."),
            (ProposalStoreError.notSignedIn, .join, "Sign in to continue."),
            (ProposalLockError.windowTooShort, .lock, "Everyone's free for less than an hour here."),
            (ProposalLockError.notEnoughCoverage(required: 0.8, actual: 0.5), .lock, "Not enough friends are free anymore. Pick another time."),
            (ProposalLockError.insufficientRecipients, .lock, "No one has joined yet."),
            (ProposalLockError.cellNotInWindow, .lock, "That time doesn't fit inside the plan."),
            (NSError(domain: "x", code: 1), .lock, "Couldn't lock. Try again."),
        ]
        for (error, action, message) in rows {
            let mapped = UserFacingError.map(error, action: action, creatorName: "Sam")
            XCTAssertEqual(mapped.message, message, "\(error) / \(action)")
            XCTAssertNotNil(mapped.details, "\(error) / \(action) keeps details")
        }
        XCTAssertEqual(UserFacingError.map(server("42501"), action: .lock).message, "Only the host can lock this plan.")
        XCTAssertEqual(UserFacingError.map(server("22023", "FC_QUORUM"), action: .lock).details, "22023 · raw server text · FC_QUORUM")
        let passthrough = UserFacingError(message: "Custom", details: nil)
        XCTAssertEqual(UserFacingError.map(passthrough, action: .lock), passthrough)
    }
}
