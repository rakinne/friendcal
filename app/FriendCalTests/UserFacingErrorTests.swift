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
            // This wave's hints (users_auth.sql, join_proposal.sql, rls.sql).
            (server("42501", "FC_NOT_SIGNED_IN"), .deleteAccount, "Sign in to continue."),
            (server("42501", "FC_ACCOUNT_DELETED"), .join, "This account has been deleted."),
            (server("P0002", "FC_NOT_FOUND"), .join, "This plan is gone."),
            (server("42501", "FC_SERVER_OWNED_FIELD"), .edit, "Couldn't save that change. Retry."),
            // 42501 must stop meaning "only the host can lock this" for the two new actions: there
            // is no host involved in deleting your own account or signing in.
            (server("42501"), .deleteAccount, "Couldn't delete your account. Sign in and try again."),
            (server("42501", "FC_NOT_CREATOR"), .deleteAccount, "Couldn't delete your account. Sign in and try again."),
            (server("42501"), .signIn, "Couldn't sign you in. Try again."),
            (server("42501", "FC_NOT_CREATOR"), .signIn, "Couldn't sign you in. Try again."),
            (server("XX000"), .deleteAccount, "Couldn't delete your account. Retry."),
            (server("XX000"), .signIn, "Couldn't sign you in. Try again."),
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

    /// protects=every FC_* identifier the SQL raises having a row in this map, by reading BOTH lists
    /// off disk and comparing them; fails_when=a raise is added in SQL without a sentence here, or
    /// the two sides spell the same refusal differently; no_claim=that the sentences are the right
    /// words, which is a copy decision, only that none is missing.
    ///
    /// This test exists because the drift it checks for actually happened. The SQL in this wave was
    /// first written with FC_ALREADY_LOCKED, FC_BAD_WINDOW, FC_BELOW_QUORUM, FC_AVAILABILITY_CHANGED
    /// and FC_PLAN_CLOSED, while the shipped Swift map had FC_LOCKED, FC_WINDOW, FC_QUORUM, FC_CHANGED
    /// and FC_CLOSED for the same five refusals. Nothing failed: the SQL tests asserted the SQL's own
    /// spellings, the Swift tests asserted Swift's, and a real refusal would have fallen through to a
    /// generic sentence in production. Two hand-maintained lists of identifiers cannot be kept in
    /// agreement by intention, so they are compared mechanically here.
    func testEveryServerHintIsMapped() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FriendCalTests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
        let sqlDir = root.appendingPathComponent("supabase")

        var raised = Set<String>()
        let files = try FileManager.default.contentsOfDirectory(at: sqlDir, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "sql" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.ranges(ofPattern: "hint = 'FC_") {
                let tail = text[match.upperBound...]
                let name = "FC_" + tail.prefix { $0.isUppercase || $0 == "_" }
                raised.insert(name)
            }
        }
        XCTAssertFalse(raised.isEmpty, "found no FC_ raises under supabase/ — did the path change?")

        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FriendCal/Services/UserFacingError.swift"), encoding: .utf8)
        var mapped = Set<String>()
        for match in source.ranges(ofPattern: "case \"FC_") {
            let tail = source[match.upperBound...]
            mapped.insert("FC_" + tail.prefix { $0.isUppercase || $0 == "_" })
        }

        let unmapped = raised.subtracting(mapped)
        XCTAssertTrue(unmapped.isEmpty,
                      "SQL raises these with no sentence in UserFacingError: \(unmapped.sorted())")
    }
}

private extension String {
    /// Every range where `pattern` occurs. Plain substring search; the patterns here are literals.
    func ranges(ofPattern pattern: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start = startIndex
        while let found = range(of: pattern, range: start..<endIndex) {
            result.append(found)
            start = found.upperBound
        }
        return result
    }
}
