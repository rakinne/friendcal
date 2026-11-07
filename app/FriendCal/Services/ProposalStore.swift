import Foundation

/// A proposal with everything a screen needs: the row, the users on it and its holds (issue #5 D2).
public struct ProposalSnapshot: Equatable {
    public var proposal: Proposal
    public var members: [User]
    public var slots: [AvailabilitySlot]

    public init(proposal: Proposal, members: [User], slots: [AvailabilitySlot]) {
        self.proposal = proposal
        self.members = members
        self.slots = slots
    }
}

/// One Invites row (D19, P6): membership only, never an overlap count. Counts live on the invite.
public struct ProposalSummary: Identifiable, Equatable {
    public var proposal: Proposal
    /// Distinct recipients so far.
    public var joinedCount: Int
    /// Created by the current user ("Hosting", design 1.7A).
    public var isHosting: Bool

    public var id: UUID { proposal.id }

    public init(proposal: Proposal, joinedCount: Int, isHosting: Bool) {
        self.proposal = proposal
        self.joinedCount = joinedCount
        self.isHosting = isHosting
    }
}

/// What `ProposalStore.changes(for:)` delivers (D11): the store's rows after a change, never a
/// row-level patch, so a session always holds exactly what the server holds.
public enum ProposalChange: Equatable {
    case snapshot(ProposalSnapshot)
}

/// Store failures. The Supabase store maps `PostgrestError` to `.server`; the in-memory store raises
/// the same codes and `FC_*` hints as lock_proposal.sql and join_proposal.sql (delta O3), so
/// `UserFacingError` is exercised without a network.
public enum ProposalStoreError: Error, Equatable {
    case notSignedIn
    case notFound(UUID)
    /// A server refusal: SQLSTATE `code`, its message, and the stable `hint` when the raise carried one.
    case server(code: String, message: String, hint: String?)
    /// The user already holds that time for another plan (`AvailabilityService.tapFreeSlot`, A2: a UX
    /// guard, not an invariant).
    case heldElsewhere
    case network(String)
}

/// The one seam between the screens and persistence (issue #5 D2, shape 1).
///
/// State machines the store owns:
///
///     proposal:  requesting --lock(window)--> locked          (join appends a recipient in both)
///     hold:      tapFree --> softHold --promote(lock)--> busy
///                                    --release / expire--> gone
///
/// Every mutation on a proposal is followed by a `.snapshot` on `changes(for:)` for that proposal.
/// `lock` is server-first (R3): the caller applies the returned proposal and never marks a lock
/// locally. The client-side collision check in `tapFree` (own commitments across plans) is a UX
/// guard; the server has no exclusion for softHolds (A2).
///
/// Main-actor isolated: the session and the screens that read it live on the main actor, and a
/// non-isolated `async` witness would run on the global executor and mutate the store's rows while
/// SwiftUI reads them. The network store (PR2) suspends on I/O inside the same isolation.
@MainActor
public protocol ProposalStore: AnyObject {
    var currentUserID: UUID? { get }
    /// Signs in (or restores) the current user. The in-memory store creates a local identity.
    func signIn(displayName: String?) async throws -> UUID
    /// Plans the current user created or joined.
    func proposals() async throws -> [ProposalSummary]
    func load(_ id: UUID) async throws -> ProposalSnapshot
    /// Creates a requesting proposal with the creator as its first recipient (D4).
    func create(_ plan: NewProposal) async throws -> Proposal
    /// Creator edits (design 5.4A): title and expected count while requesting; the window only while
    /// no hold exists; nothing once locked. Server-owned fields on `proposal` are ignored.
    func update(_ proposal: Proposal) async throws -> Proposal
    /// Appends the current user to the recipients, idempotently, on a requesting or locked plan (D3, D13).
    func join(_ id: UUID) async throws -> Proposal
    /// The current user's holds across every plan plus their Busy blocks as `.busy` slots (O5).
    func myCommitments() async throws -> [AvailabilitySlot]
    func tapFree(proposalID: UUID, range: DateRange, expiresAt: Date?) async throws -> AvailabilitySlot
    /// Removes one of the current user's own holds (C3).
    func release(slotID: UUID) async throws
    /// Locks `window` (already validated by `ProposalService.validateLock`); the server re-derives
    /// coverage and may refuse (22023 / 40001 / 55000 / 42501).
    func lock(_ id: UUID, window: DateRange) async throws -> Proposal
    /// A stream of snapshots for one open proposal; finishes when cancelled.
    func changes(for id: UUID) -> AsyncStream<ProposalChange>
}
