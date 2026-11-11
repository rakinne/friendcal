import XCTest
@testable import FriendCalCore

/// Statuses, core lane. The server side is supabase/tests/statuses_test.sql; this asserts the same
/// rules against the in-memory store, which mirrors statuses.sql.
@MainActor
final class InMemoryStatusStoreTests: XCTestCase {
    private let sam = User(id: UUID(), displayName: "Sam")
    private let maya = User(id: UUID(), displayName: "Maya")
    private let cleo = User(id: UUID(), displayName: "Cleo")
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var store: InMemoryProposalStore!

    override func setUp() async throws {
        store = InMemoryProposalStore(users: [sam, maya, cleo], currentUserID: maya.id, now: { [unowned self] in self.clock })
        // Sam and Maya connect through a link; Cleo stays a stranger.
        let token = try await store.friendLink()
        become(sam)
        _ = try await store.acceptFriendLink(token: token)
        become(maya)
    }

    private func become(_ user: User) {
        store.seed(users: store.users, proposals: store.proposals, slots: store.slots, busyBlocks: store.busyBlocks,
                   places: store.places, votes: store.votes, currentUserID: user.id)
    }

    private func hint(_ work: () async throws -> Void) async -> String? {
        do { try await work(); return "no error" } catch let ProposalStoreError.server(_, _, hint) { return hint } catch { return "\(error)" }
    }

    /// protects=a status a person sets reaches their friend, and the person sees their own;
    /// fails_when=friendStatuses() omits a friend or the caller.
    func testFriendSeesStatus() async throws {
        try await store.setMyStatus(FriendStatus(kind: .movies, message: "no spoilers", since: clock, until: clock.addingTimeInterval(3600)))
        become(sam)
        let seen = try await store.friendStatuses()
        XCTAssertEqual(seen[maya.id]?.kind, .movies)
        XCTAssertEqual(seen[maya.id]?.message, "no spoilers")
        become(maya)
        let own = try await store.friendStatuses()
        XCTAssertEqual(own[maya.id]?.kind, .movies)
    }

    /// protects=a stranger never reads a status; fails_when=the friendship check is dropped.
    func testStrangerSeesNothing() async throws {
        try await store.setMyStatus(FriendStatus(kind: .gym, since: clock))
        become(cleo)
        let seen = try await store.friendStatuses()
        XCTAssertTrue(seen.isEmpty)
    }

    /// protects=an expired status is not returned; fails_when=reads ignore `until`.
    func testExpiredStatusIsHidden() async throws {
        try await store.setMyStatus(FriendStatus(kind: .free, since: clock, until: clock.addingTimeInterval(60)))
        clock = clock.addingTimeInterval(120)
        become(sam)
        let seen = try await store.friendStatuses()
        XCTAssertNil(seen[maya.id])
    }

    /// protects=setting replaces and clearing removes (twice is fine); fails_when=two rows survive.
    func testReplaceAndClear() async throws {
        try await store.setMyStatus(FriendStatus(kind: .gym, since: clock))
        try await store.setMyStatus(FriendStatus(kind: .napping, since: clock))
        var seen = try await store.friendStatuses()
        XCTAssertEqual(seen[maya.id]?.kind, .napping)
        try await store.clearMyStatus()
        try await store.clearMyStatus()
        seen = try await store.friendStatuses()
        XCTAssertNil(seen[maya.id])
    }

    /// protects=a status that ended already is refused with FC_BAD_STATUS, as the server does;
    /// fails_when=the store accepts a past end.
    func testPastEndIsRefused() async {
        let h = await hint { try await store.setMyStatus(FriendStatus(kind: .free, since: clock.addingTimeInterval(-120), until: clock.addingTimeInterval(-60))) }
        XCTAssertEqual(h, "FC_BAD_STATUS")
    }

    /// protects=removing the friendship hides the status again; fails_when=the check is cached.
    func testRemovedFriendSeesNothing() async throws {
        try await store.setMyStatus(FriendStatus(kind: .gym, since: clock))
        try await store.removeFriend(sam.id)
        become(sam)
        let seen = try await store.friendStatuses()
        XCTAssertNil(seen[maya.id])
    }
}
