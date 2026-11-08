import XCTest
@testable import FriendCalCore

/// The one named blanking site, asserted on WHOLE VALUES rather than field by field.
///
/// Why that distinction carries the weight here: a field-by-field test ("hiddenFrom is empty",
/// "visibility is public") passes forever while being blind to the only failure that matters, which
/// is a field nobody thought to check. `BusyBlock` gained `sourceProposalID` during this wave, and a
/// field-by-field test written before it would still be green afterwards with the provenance leaking
/// straight through. So these compare complete values, and pin the field COUNT as well: adding a
/// property to either type fails a test here and forces someone to decide whether it is safe to show.
final class BusyBlockSanitizeTests: XCTestCase {
    private let viewer = UUID(uuidString: "00000000-0000-0000-0000-00000000FFFF")!
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let plan = UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!
    private let blockID = UUID(uuidString: "00000000-0000-0000-0000-00000000BBBB")!
    private let created = Date(timeIntervalSince1970: 1_780_000_000)

    private var stealthBlock: BusyBlock {
        BusyBlock(
            id: blockID,
            userID: owner,
            range: DateRange(lower: created, upper: created.addingTimeInterval(3600)),
            visibility: .stealth,
            hiddenFrom: [viewer],
            sourceProposalID: plan,
            createdAt: created
        )
    }

    /// protects=the exact value a blanked block takes, in full; fails_when=any correlation field
    /// survives blanking, or the identity/time fields are altered (which would make the row useless);
    /// no_claim=what the server sends, which supabase/tests/rls_test.sql covers.
    func testSanitizedIsExactlyTheSafeValue() {
        let expected = BusyBlock(
            id: blockID,
            userID: owner,
            range: DateRange(lower: created, upper: created.addingTimeInterval(3600)),
            visibility: .public,
            hiddenFrom: [],
            sourceProposalID: nil,
            createdAt: created
        )
        XCTAssertEqual(stealthBlock.sanitized, expected, "whole-value: a new field must be decided on, not defaulted past")
    }

    /// protects=the narrow type's exact value; fails_when=SanitizedBusy gains a field that gets
    /// populated from the block; no_claim=rendering.
    func testSanitizedBusyIsExactlyTheSafeValue() {
        let expected = SanitizedBusy(
            id: blockID,
            userID: owner,
            range: DateRange(lower: created, upper: created.addingTimeInterval(3600))
        )
        XCTAssertEqual(stealthBlock.sanitizedBusy, expected)
    }

    /// protects=the field count of both types, so a property added later cannot ride through
    /// blanking unexamined; fails_when=a property is added to BusyBlock or SanitizedBusy;
    /// no_claim=that a new field is unsafe -- only that someone must look.
    ///
    /// When this fails: add the field to the expected values above, decide whether `sanitized` should
    /// clear it, and bump the count. That deliberate stop is the entire purpose.
    func testFieldCountsArePinned() {
        let blockFields = Mirror(reflecting: stealthBlock).children.count
        let sanitizedFields = Mirror(reflecting: stealthBlock.sanitizedBusy).children.count
        XCTAssertEqual(blockFields, 7, "BusyBlock gained or lost a field — re-check `sanitized`")
        XCTAssertEqual(sanitizedFields, 3, "SanitizedBusy gained or lost a field — re-check what is safe")
    }

    /// protects=the blanked shape being IDENTICAL for an excluded viewer and an included one, which
    /// is what makes the row un-fingerprintable; fails_when=blanking becomes conditional on the
    /// viewer; no_claim=the absence of timing side channels, which is a server concern.
    func testBlankedShapeDoesNotDependOnTheViewer() {
        let excluded = stealthBlock.sanitized
        // The same block as seen by someone not in hiddenFrom at all.
        var includedSource = stealthBlock
        includedSource.hiddenFrom = []
        includedSource.visibility = .public
        XCTAssertEqual(excluded, includedSource.sanitized,
                       "an excluded viewer and an included one must receive the same value")
    }

    /// protects=blanking being idempotent, so applying it twice (defence in depth at a decode site)
    /// is safe; fails_when=`sanitized` starts mutating something cumulatively.
    func testSanitizingTwiceChangesNothing() {
        XCTAssertEqual(stealthBlock.sanitized, stealthBlock.sanitized.sanitized)
    }

    /// protects=an ordinary public block surviving blanking unchanged except for provenance, so the
    /// normal path is not quietly degraded; fails_when=blanking drops the range or re-ids the row.
    func testOrdinaryBlockKeepsItsIdentityAndTime() {
        let plain = BusyBlock(id: blockID, userID: owner,
                              range: DateRange(lower: created, upper: created.addingTimeInterval(1800)),
                              createdAt: created)
        XCTAssertEqual(plain.sanitized, plain, "nothing to strip, nothing changed")
    }

    /// protects=provenance being dropped for EVERY viewer including the block's own owner, matching
    /// the server, where no client holds SELECT on source_proposal_id; fails_when=someone decides the
    /// owner may read their own provenance off the block instead of through my_commitments().
    func testProvenanceIsDroppedEvenForTheOwner() {
        var mine = stealthBlock
        mine.userID = viewer // the viewer's own block, from a plan
        mine.hiddenFrom = []
        XCTAssertNotNil(mine.sourceProposalID)
        XCTAssertNil(mine.sanitized.sourceProposalID,
                     "provenance reaches the client through my_commitments() or not at all")
    }

    /// protects=every blanking path in the app going through the one site; fails_when=a service
    /// rebuilds a "safe" block with its own field list again; no_claim=sites added in future waves,
    /// which this assertion cannot see.
    @MainActor
    func testStoreReadGoesThroughTheNamedSite() async throws {
        let store = InMemoryProposalStore()
        store.busyBlocks = [stealthBlock]
        let read = try await store.fetchBusyBlocks(
            for: viewer,
            in: DateRange(lower: created.addingTimeInterval(-60), upper: created.addingTimeInterval(7200))
        )
        XCTAssertEqual(read, [stealthBlock.sanitized], "the store's read is exactly the named blanking")
    }

    /// protects=StealthService's transform being the same one, not a second implementation;
    /// fails_when=StealthService re-lists the safe fields.
    func testStealthServiceDelegatesToTheNamedSite() {
        XCTAssertEqual(StealthService().sanitize(stealthBlock, for: viewer), stealthBlock.sanitizedBusy)
    }
}
