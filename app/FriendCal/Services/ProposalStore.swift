import Foundation

/// A proposal with everything a screen needs: the row, the users on it and its holds (issue #5 D2).
public struct ProposalSnapshot: Equatable {
    public var proposal: Proposal
    public var members: [User]
    public var slots: [AvailabilitySlot]
    public var places: [Place]
    public var votes: [PlaceVote]

    /// `places` and `votes` have NO default, on purpose. A default of `[]` would let any caller that
    /// builds a snapshot by hand (the session's lock and edit paths did) silently blank the board;
    /// without one, the compiler finds every call site that has to say what it holds.
    public init(proposal: Proposal, members: [User], slots: [AvailabilitySlot], places: [Place], votes: [PlaceVote]) {
        self.proposal = proposal
        self.members = members
        self.slots = slots
        self.places = places
        self.votes = votes
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

/// Where the current identity stands. The screens switch on this rather than on
/// `currentUserID != nil`, because a bare optional cannot express "signing in" or "sign-in failed",
/// and a root view that cannot express them has to invent them as local `@State` -- which is how two
/// screens end up disagreeing about whether anyone is signed in.
public enum AuthState: Equatable, Sendable {
    case signedOut
    case signingIn
    case signedIn(UUID)
    /// Sign-in was attempted and refused. Carries the mapped sentence, so the gate can show it
    /// without re-deriving it, and keeps the person on the gate rather than dropping them into a
    /// signed-out shell that looks identical to never having tried.
    case failed(UserFacingError)

    public var userID: UUID? {
        if case .signedIn(let id) = self { return id }
        return nil
    }

    public var isSignedIn: Bool { userID != nil }
}

/// What `delete_account()` reports back. Mirrors the RPC's jsonb one field at a time.
///
/// `alreadyDeleted` is the one that matters for correctness: the app can be killed between sending
/// the call and seeing the result, and on relaunch it cannot know whether the transaction committed.
/// A resumed deletion therefore succeeds and says so, instead of refusing and leaving the client to
/// decide whether a refusal means failure or completion (CEO review C3).
public struct AccountDeletionReceipt: Equatable, Sendable {
    public var alreadyDeleted: Bool
    public var cancelledPlans: Int
    public var releasedHolds: Int
    public var lockedPlansKept: Int

    public init(alreadyDeleted: Bool, cancelledPlans: Int, releasedHolds: Int, lockedPlansKept: Int) {
        self.alreadyDeleted = alreadyDeleted
        self.cancelledPlans = cancelledPlans
        self.releasedHolds = releasedHolds
        self.lockedPlansKept = lockedPlansKept
    }
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
    /// The signed-in identity changed while this operation was suspended, so its result belongs to
    /// somebody else. Raised by the store rather than by each caller: an operation started as A and
    /// resumed after a sign-out and sign-in as B must not write as B (outside voice F6).
    case identityChanged
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
    /// Where the identity stands, as a value the screens can switch on.
    var authState: AuthState { get }
    /// Bumped on every sign-in, sign-out and deletion.
    ///
    /// Operations capture this before they suspend and re-check it after, and fail rather than
    /// complete if it moved. Without it, an action started by A that suspends across a sign-out and
    /// a sign-in as B resumes holding A's intent and B's identity, and writes it -- the kind of bug
    /// that needs two people and bad timing to reproduce and is invisible to a double-tap test.
    var identityGeneration: Int { get }
    /// A stream of auth states, so an `@Observable` projection can follow the store instead of each
    /// screen reading a getter and hoping to be re-rendered. The store stays the single owner of
    /// identity; this is how that ownership becomes observable.
    var authChanges: AsyncStream<AuthState> { get }

    /// Signs in (or restores) the current user. The in-memory store creates a local identity.
    func signIn(displayName: String?) async throws -> UUID
    /// Drops the current identity. Not a failure path: it always succeeds and always ends signedOut.
    func signOut() async
    /// Deletes the current user's account: cancels their open plans, releases every hold on those
    /// plans (not only their own), leaves locked plans standing, and anonymizes their row.
    ///
    /// No parameter, deliberately: there is no shape of this call that deletes someone else. See
    /// `delete_account()` in supabase/users_auth.sql, which this mirrors. Idempotent -- calling it on
    /// an already-deleted account succeeds with `alreadyDeleted`, so a deletion interrupted by the
    /// app being killed converges on relaunch.
    func deleteAccount() async throws -> AccountDeletionReceipt
    /// Plans the current user created or joined.
    func proposals() async throws -> [ProposalSummary]
    func load(_ id: UUID) async throws -> ProposalSnapshot
    /// Creates a requesting proposal with the creator as its first recipient (D4).
    func create(_ plan: NewProposal) async throws -> Proposal
    /// Creator edits (design 5.4A): title and expected count while requesting; the window only while
    /// no hold exists; nothing once locked. The city (`area`) can be replaced while requesting, even
    /// when the dates are frozen, but never cleared (FC_AREA_REQUIRED). Server-owned fields on
    /// `proposal` are ignored.
    func update(_ proposal: Proposal) async throws -> Proposal
    /// Appends the current user to the recipients, idempotently, on a requesting or locked plan (D3, D13).
    func join(_ id: UUID) async throws -> Proposal
    /// Everything the current user is on the hook for, at or after `from`: their unexpired holds and
    /// their Busy blocks, each carrying the plan that created it and -- only when this viewer is
    /// allowed to know it -- that plan's name.
    ///
    /// Returns `Commitment`, not `[AvailabilitySlot]`, because a slot cannot express the two things
    /// this screen needs. It has nowhere to put the plan's title, and nowhere to distinguish "a plan
    /// you may not name" from "no plan at all" -- a surprise being thrown for you produces a real
    /// block that must appear and must stay nameless, and `sourceProposalID == nil` already means
    /// something else. The server answers this through `my_commitments(p_from)`, a security definer
    /// RPC that re-applies the proposals read predicate per row; provenance is not readable any other
    /// way, since no client holds SELECT on `busy_blocks.source_proposal_id`.
    ///
    /// `from` is an OVERLAP horizon, not a start filter: a commitment that began before it and is
    /// still running is included.
    func myCommitments(from: Date) async throws -> [Commitment]
    // MARK: Places (#10, #11). Server-first and without optimistic updates: the caller awaits the store
    // and applies the snapshot. Refusals carry the SQLSTATE and FC_* hint #11's error contract names.

    /// Adds a place to a plan. Idempotent for a duplicate of an ACTIVE place: returns the existing row.
    /// A duplicate of a vetoed place is refused (FC_VETOED).
    func suggestPlace(proposalID: UUID, _ place: NewPlace) async throws -> Place
    /// Casts, moves or (with nil) clears the caller's one vote on this plan.
    func votePlace(proposalID: UUID, placeID: UUID?) async throws
    /// Host only: passes on a place (clearing its votes) or brings it back with zero votes.
    func vetoPlace(placeID: UUID, vetoed: Bool) async throws -> Place
    /// Suggester only: withdraws their own place; its votes go with it.
    func removePlace(placeID: UUID) async throws

    // MARK: Poke and Tag along (supabase/social.sql). Server-first like places: the caller awaits the
    // store and shows what it answers. These are the ONLY entry points, so a poke sent from Home, from a
    // row on Groups and from the Pokes tab is the same call with the same rules.

    /// Pokes a friend, optionally about a plan. One live poke per friend at a time: a second call
    /// while the first is still out returns that poke with `isNew == false` and notifies nobody.
    /// Poking someone who has a live poke out to the caller acknowledges theirs. Refused for
    /// yourself (FC_SELF_POKE) and for anyone the caller shares no plan with (FC_NOT_FRIEND).
    func sendPoke(to userID: UUID, about proposalID: UUID?) async throws -> PokeReceipt
    /// The recipient saw it. Idempotent, and a no-op on a poke that already ended; a poke that is
    /// not the caller's is FC_POKE_NOT_FOUND, exactly like one that does not exist.
    func acknowledgePoke(_ id: UUID, via: Poke.AckVia) async throws -> Poke
    /// Joins a locked plan that has not ended: the caller becomes a recipient and an attendee, gets
    /// the plan's Busy block, and the host is notified. Idempotent. Refusals: FC_NOT_FOUND (also for
    /// a hidden viewer), FC_NOT_LOCKED, FC_CLOSED, FC_PLAN_OVER, FC_BUSY.
    func tagAlong(_ proposalID: UUID) async throws -> Proposal
    /// The caller's pokes in both directions and the tag alongs on plans they host.
    func inbox() async throws -> SocialInbox
    /// Stores this device's APNs token for the caller, so pokes and tag alongs reach it.
    func registerDevice(token: String, sandbox: Bool) async throws

    func tapFree(proposalID: UUID, range: DateRange, expiresAt: Date?) async throws -> AvailabilitySlot
    /// Removes one of the current user's own holds (C3).
    func release(slotID: UUID) async throws
    /// Locks `window` (already validated by `ProposalService.validateLock`); the server re-derives
    /// coverage and may refuse (22023 / 40001 / 55000 / 42501).
    func lock(_ id: UUID, window: DateRange) async throws -> Proposal
    /// A stream of snapshots for one open proposal; finishes when cancelled.
    func changes(for id: UUID) -> AsyncStream<ProposalChange>
}
