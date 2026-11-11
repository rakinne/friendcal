import Foundation

/// The in-app `ProposalStore` (issue #5 D2, D7): fixture-seeded, Simulator-testable, no credentials.
/// It is the real seam, not a stub: every rule lock_proposal.sql and join_proposal.sql enforce is
/// mirrored here with the same SQLSTATE and `FC_*` hint, so the session and the screens behave the
/// same on demo data as on the network store that PR2 adds. Absorbs the former DebugProposalModel
/// and MockSupabaseService (S1, S2). Main-actor isolated, so overlapping taps never mutate the rows
/// from two threads; only the `changes(for:)` continuations are touched off-actor (on stream
/// termination), and those stay behind `lock`.
@MainActor
public final class InMemoryProposalStore: ProposalStore {
    public enum Operation: Hashable, CaseIterable {
        case proposals, load, create, update, join, tapFree, release, lock, myCommitments, signIn, deleteAccount
        case suggestPlace, votePlace, vetoPlace, removePlace
        case sendPoke, acknowledgePoke, tagAlong, inbox, registerDevice
        case friendLink, resetFriendLink, previewFriendLink, acceptFriendLink, friends, removeFriend
    }

    public private(set) var users: [User]
    public private(set) var proposals: [Proposal]
    public private(set) var slots: [AvailabilitySlot]
    public var busyBlocks: [BusyBlock]
    public private(set) var places: [Place]
    public private(set) var votes: [PlaceVote]
    /// Poke and Tag along (supabase/social.sql), row for row.
    public private(set) var pokes: [Poke] = []
    public private(set) var tagAlongs: [TagAlong] = []
    /// device_tokens: token -> owner.
    public private(set) var deviceTokens: [String: UUID] = [:]
    /// push_outbox: what the server would hand to APNs. Tests read it to assert who was told what.
    public private(set) var outbox: [QueuedPush] = []
    /// friendships, link for link: one entry per pair, with when it began (supabase/friends.sql).
    public private(set) var friendships: [FriendPair: Date] = [:]
    /// friend_links: one per person.
    public private(set) var friendLinks: [UUID: FriendLinkRecord] = [:]
    /// friend_removals: written only when a friendship was actually removed.
    public private(set) var friendRemovals: Set<FriendRemoval> = []
    /// `-FriendCalFriendLink valid|dead|own|already`: what the store answers for ANY opened token, so
    /// a UI test needs no real link. nil answers by the real rules.
    public var friendLinkScenario: FriendLinkScenario?
    public private(set) var currentUserID: UUID?
    public private(set) var authState: AuthState = .signedOut
    public private(set) var identityGeneration: Int = 0
    /// Ids whose account has been deleted. A tombstone, like users.deleted_at: the row survives so a
    /// locked plan can still name its attendee.
    public private(set) var deletedUserIDs: Set<UUID> = []
    nonisolated(unsafe) private var authContinuations: [UUID: AsyncStream<AuthState>.Continuation] = [:]
    /// Injected clock (C2): expiry, createdAt and lockedAt read it.
    public var now: () -> Date
    /// Test hook (design 2.3A): the next call of a listed operation throws its error instead of
    /// running, so the error map and every revert path are exercised without a network.
    public var failNext: [Operation: Error] = [:]

    /// What happened on the server while the viewer's screen was stale (UI tests, design 2.8A): applied
    /// silently, with no stream emission, just before the next vote, so the vote meets the real refusal
    /// and the screen can only learn the truth by reconciling after that error.
    public enum StaleChange: String { case vetoed, locked, removed }

    /// Two people, smaller id first, like `friendships (user_a, user_b)`.
    public struct FriendPair: Hashable, Sendable {
        public let a: UUID
        public let b: UUID
        public init(_ x: UUID, _ y: UUID) {
            if x.uuidString <= y.uuidString { a = x; b = y } else { a = y; b = x }
        }
        public func other(than me: UUID) -> UUID? { me == a ? b : (me == b ? a : nil) }
    }

    /// One friend_links row.
    public struct FriendLinkRecord: Equatable, Sendable {
        public var token: String
        public var tokenAccepts = 0
        public var acceptCount = 0
        public var mintCount = 1
    }

    public struct FriendRemoval: Hashable, Sendable {
        public var remover: UUID
        public var removed: UUID
    }

    public enum FriendLinkScenario: String, Sendable { case valid, dead, own, already }

    /// The 50th accept works and the 51st is dead (friends.sql).
    public static let friendLinkCap = 50
    /// The inviter `-FriendCalFriendLink valid|already` answers with.
    public static let scenarioInviterID = UUID(uuidString: "00000000-0000-0000-0000-000000006001")!

    /// One push_outbox row.
    public struct QueuedPush: Equatable, Sendable {
        public enum Kind: String, Sendable { case poke, tagAlong = "tag_along", friendJoined = "friend_joined" }
        public var recipientID: UUID
        public var kind: Kind
        public var title: String
        public var body: String
        /// nil for `friend_joined`: the app does not route that kind yet (the push forwarder work).
        public var route: PushRoute?
        public var expiresAt: Date?
    }
    public var staleBeforeNextVote: StaleChange?
    /// Artificial latency for every operation (loading states in UI tests).
    public var latency: Duration = .zero

    private let availability = AvailabilityService()
    nonisolated(unsafe) private var continuations: [UUID: [UUID: AsyncStream<ProposalChange>.Continuation]] = [:]
    private let lock = NSLock()

    public init(users: [User] = [], proposals: [Proposal] = [], slots: [AvailabilitySlot] = [], busyBlocks: [BusyBlock] = [], places: [Place] = [], votes: [PlaceVote] = [], currentUserID: UUID? = nil, now: @escaping () -> Date = { .now }) {
        self.users = users
        self.proposals = proposals
        self.slots = slots
        self.busyBlocks = busyBlocks
        self.places = places
        self.votes = votes
        self.currentUserID = currentUserID
        self.now = now
        self.authState = currentUserID.map(AuthState.signedIn) ?? .signedOut
    }

    // MARK: ProposalStore

    public func signIn(displayName: String?) async throws -> UUID {
        if let id = currentUserID { return id }
        setAuth(.signingIn, bumpGeneration: false)
        do {
            try await gate(.signIn)
        } catch {
            // A refused sign-in leaves the gate showing why, not a signed-out shell that looks the
            // same as never having tried.
            setAuth(.failed(UserFacingError.map(error, action: .signIn)), bumpGeneration: false)
            throw error
        }
        let user = User(id: UUID(), displayName: displayName ?? "You")
        users.append(user)
        currentUserID = user.id
        setAuth(.signedIn(user.id), bumpGeneration: true)
        return user.id
    }

    /// Demo and UI tests (`-FriendCalSignedOut 1`): the fixture's data with nobody signed in, so the
    /// sign-in gate shows and a pending link can be seen waiting behind it.
    public func forgetIdentity() {
        currentUserID = nil
        authState = .signedOut
    }

    public func signOut() async {
        currentUserID = nil
        setAuth(.signedOut, bumpGeneration: true)
    }

    public func deleteAccount() async throws -> AccountDeletionReceipt {
        let me = try await authorize(.deleteAccount)

        // Already a tombstone: report the terminal state rather than refusing, so a deletion the app
        // was killed in the middle of converges on relaunch (C3).
        if deletedUserIDs.contains(me) {
            let kept = proposals.filter { $0.createdBy == me && $0.status == .locked }.count
            currentUserID = nil
            setAuth(.signedOut, bumpGeneration: true)
            return AccountDeletionReceipt(alreadyDeleted: true, cancelledPlans: 0,
                                          releasedHolds: 0, lockedPlansKept: kept)
        }

        let cancelled = proposals.filter { $0.createdBy == me && $0.status == .requesting }.map(\.id)
        for id in cancelled {
            guard let index = proposals.firstIndex(where: { $0.id == id }) else { continue }
            proposals[index].status = .cancelled
        }

        // EVERY softHold on the cancelled plans, whoever placed it -- not only the departing user's.
        // A hold on a plan that no longer exists would go on blocking its owner's own choices, and a
        // hold with no expiry never lapses on its own (outside voice F8).
        let before = slots.count
        slots.removeAll { $0.state == .softHold && $0.sourceProposalID.map(cancelled.contains) == true }
        // And their own holds on everyone else's plans.
        slots.removeAll { $0.state == .softHold && $0.userID == me }
        let released = before - slots.count

        // Locked plans keep their Busy blocks and this person's attendee membership: that time is
        // something other people have already arranged around. (Whether 5.1.1(v) permits retaining
        // it is unresolved -- CEO review C7 -- and is a policy question, not a code one.)
        let kept = proposals.filter { $0.createdBy == me && $0.status == .locked }.count

        // The leaver's votes on plans that are still collecting: a departed person must not decide a
        // winner. Plans cancelled just above are no longer requesting, so their votes stay as history,
        // as do votes on locked plans. Suggestions stay: the tombstone survives, so they stay valid.
        let collecting = Set(proposals.filter { $0.status == .requesting }.map(\.id))
        let votedOn = Set(votes.filter { $0.voterID == me && collecting.contains($0.proposalID) }.map(\.proposalID))
        votes.removeAll { $0.voterID == me && collecting.contains($0.proposalID) }

        // Friendships, the link and removal records in both directions go with the account: a deleted
        // person is nobody's friend, holds no link, and nobody keeps a record against them.
        friendships = friendships.filter { $0.key.other(than: me) == nil }
        friendLinks[me] = nil
        friendRemovals = friendRemovals.filter { $0.remover != me && $0.removed != me }

        // The tombstone. The row stays; the identifying content goes.
        if let index = users.firstIndex(where: { $0.id == me }) {
            users[index].displayName = User.deletedDisplayName
            users[index].avatarURL = nil
        }
        deletedUserIDs.insert(me)
        // friendcal_purge_push_on_delete: a departed account stops receiving.
        deviceTokens = deviceTokens.filter { $0.value != me }
        outbox.removeAll { $0.recipientID == me }

        for id in Set(cancelled).union(votedOn) { emit(id) }
        currentUserID = nil
        setAuth(.signedOut, bumpGeneration: true)
        return AccountDeletionReceipt(alreadyDeleted: false, cancelledPlans: cancelled.count,
                                      releasedHolds: released, lockedPlansKept: kept)
    }

    public var authChanges: AsyncStream<AuthState> {
        AsyncStream { continuation in
            let token = UUID()
            continuation.yield(authState)
            lock.withLock { authContinuations[token] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.authContinuations.removeValue(forKey: token) }
            }
        }
    }

    public func proposals() async throws -> [ProposalSummary] {
        let me = try await authorize(.proposals)
        return proposals
            .filter { $0.createdBy == me || $0.isRecipient(me) }
            .map { ProposalSummary(proposal: $0, joinedCount: $0.joinedCount, isHosting: $0.createdBy == me) }
    }

    public func load(_ id: UUID) async throws -> ProposalSnapshot {
        try await gate(.load)
        return try snapshot(of: id)
    }

    public func create(_ plan: NewProposal) async throws -> Proposal {
        let me = try await authorize(.create)
        ensureUser(me)
        // The SQL check `proposals_area_all_or_none`: a city that is set must be valid.
        if let area = plan.area, !area.isValid { throw Self.badCity() }
        let proposal = Proposal(id: UUID(), title: plan.title, window: plan.window, createdBy: me,
                                distribution: Distribution(mode: .newGroup, recipientIDs: [me]),
                                status: .requesting, createdAt: now(), area: plan.area, expectedCount: plan.expectedCount)
        proposals.append(proposal)
        return proposal
    }

    public func update(_ edited: Proposal) async throws -> Proposal {
        let me = try await authorize(.update)
        guard let index = proposals.firstIndex(where: { $0.id == edited.id }) else { throw ProposalStoreError.notFound(edited.id) }
        var current = proposals[index]
        guard current.createdBy == me else {
            throw ProposalStoreError.server(code: "42501", message: "only the proposal creator can edit it", hint: "FC_NOT_CREATOR")
        }
        guard current.status == .requesting else {
            throw ProposalStoreError.server(code: "55000", message: "proposal is \(current.status.rawValue), not requesting", hint: "FC_LOCKED")
        }
        if edited.window != current.window, slots.contains(where: { $0.sourceProposalID == current.id && $0.state == .softHold }) {
            throw ProposalStoreError.server(code: "22023", message: "dates are locked once friends have marked times", hint: "FC_DATES_FROZEN")
        }
        // The city (#10 R1): replaced while requesting, even with the dates frozen, but never cleared.
        // Mirrors the edit guard in rls.sql; the status rule above already answered FC_LOCKED.
        if current.area != nil, edited.area == nil {
            throw ProposalStoreError.server(code: "22023", message: "a plan keeps its city; replace it instead of clearing it", hint: "FC_AREA_REQUIRED")
        }
        if let area = edited.area, !area.isValid { throw Self.badCity() }
        current.title = edited.title
        current.window = edited.window
        current.expectedCount = edited.expectedCount
        current.area = edited.area
        proposals[index] = current
        emit(current.id)
        return current
    }

    public func join(_ id: UUID) async throws -> Proposal {
        let me = try await authorize(.join)
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { throw ProposalStoreError.notFound(id) }
        var p = proposals[index]
        guard p.status == .requesting || p.status == .locked else {
            throw ProposalStoreError.server(code: "55000", message: "proposal is \(p.status.rawValue)", hint: "FC_CLOSED")
        }
        ensureUser(me)
        if !p.distribution.recipientIDs.contains(me) {
            p.distribution.recipientIDs.append(me)
            if p.status == .locked { p.postLockRecipientIDs.append(me) }
            proposals[index] = p
            emit(id)
        }
        return p
    }

    public func myCommitments(from: Date) async throws -> [Commitment] {
        let me = try await authorize(.myCommitments)
        return Commitment.live(commitments(of: me), from: from, now: now())
    }

    // MARK: Places (#11's contract, check for check)

    /// Mirrors `friendcal_places_plan` in places.sql, in the same order. The excluded caller and the
    /// missing plan share ONE raise, and the exclusion is tested against `hiddenFrom` directly, never
    /// through `isReadable(by:)`: that is also false for a non-member, and a non-member who is not
    /// excluded must get FC_NOT_MEMBER, exactly as the SQL guard does.
    private func applyStaleChange(proposalID: UUID, placeID: UUID?) {
        guard let change = staleBeforeNextVote else { return }
        staleBeforeNextVote = nil
        switch change {
        case .vetoed:
            guard let placeID, let i = places.firstIndex(where: { $0.id == placeID }) else { return }
            places[i].vetoedAt = now()
            votes.removeAll { $0.placeID == placeID }
        case .removed:
            guard let placeID else { return }
            places.removeAll { $0.id == placeID }
            votes.removeAll { $0.placeID == placeID }
        case .locked:
            guard let i = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
            var p = proposals[i]
            let window = DateRange(lower: p.window.lowerBound, upper: p.window.lowerBound.addingTimeInterval(2 * 3600))
            ProposalService.apply(window: window, to: &p, attendees: p.joinedIDs, at: now())
            p.lockedPlaceID = PlaceBoard.winner(places: places.filter { $0.proposalID == proposalID }, votes: votes.filter { $0.proposalID == proposalID })
            proposals[i] = p
        }
    }

    private func placePlan(_ id: UUID?, as me: UUID) throws -> (index: Int, plan: Proposal) {
        guard let id, let index = proposals.firstIndex(where: { $0.id == id }), !proposals[index].hiddenFrom.contains(me) else {
            throw Self.refusal("P0002", "no such plan", "FC_NOT_FOUND")
        }
        let plan = proposals[index]
        if deletedUserIDs.contains(me) { throw Self.refusal("42501", "this account has been deleted", "FC_ACCOUNT_DELETED") }
        guard plan.isCreator(me) || plan.isRecipient(me) else { throw Self.refusal("42501", "you are not part of this plan", "FC_NOT_MEMBER") }
        if plan.status == .locked { throw Self.refusal("55000", "this plan is locked", "FC_LOCKED") }
        if plan.status != .requesting { throw Self.refusal("55000", "this plan is \(plan.status.rawValue)", "FC_CLOSED") }
        return (index, plan)
    }

    private static func refusal(_ code: String, _ message: String, _ hint: String) -> ProposalStoreError {
        .server(code: code, message: message, hint: hint)
    }

    private static func badCity() -> ProposalStoreError {
        .server(code: "23514", message: "the city violates proposals_area_all_or_none", hint: nil)
    }

    private func activePlaces(on plan: UUID) -> [Place] { places.filter { $0.proposalID == plan && !$0.isVetoed } }

    /// The personal cap before the plan cap, because it is the more actionable message.
    private func checkCaps(plan: UUID, suggester: UUID) throws {
        if activePlaces(on: plan).filter({ $0.suggestedBy == suggester }).count >= PlaceBoard.perPersonLimit {
            throw Self.refusal("54000", "you have suggested \(PlaceBoard.perPersonLimit) places already", "FC_PLACE_LIMIT")
        }
        if activePlaces(on: plan).count >= PlaceBoard.planLimit {
            throw Self.refusal("54000", "this plan already has \(PlaceBoard.planLimit) places", "FC_PLAN_FULL")
        }
    }

    public func suggestPlace(proposalID: UUID, _ place: NewPlace) async throws -> Place {
        let me = try await authorize(.suggestPlace)
        let (_, plan) = try placePlan(proposalID, as: me)
        guard plan.area != nil else { throw Self.refusal("P0001", "the host has not picked a city yet", "FC_NO_AREA") }

        // Field shape only, with the SQL's trimming: `btrim` removes spaces, `char_length` counts code points.
        let normalized = NewPlace(name: PlaceText.trim(place.name), address: PlaceText.trimmedOrNil(place.address),
                                  latitude: place.latitude, longitude: place.longitude, mapRef: PlaceText.trimmedOrNil(place.mapRef))
        guard !normalized.name.isEmpty, normalized.name.unicodeScalars.count <= 120,
              (normalized.address?.unicodeScalars.count ?? 0) <= 240,
              (normalized.mapRef?.unicodeScalars.count ?? 0) <= 200,
              normalized.latitude.isFinite, normalized.longitude.isFinite,
              (-90.0...90.0).contains(normalized.latitude), (-180.0...180.0).contains(normalized.longitude) else {
            throw Self.refusal("22023", "invalid place", "FC_BAD_PLACE")
        }

        // An active duplicate returns the existing row; a duplicate of only a vetoed place is refused.
        if let match = PlaceBoard.existing(matching: normalized, in: places.filter { $0.proposalID == proposalID }) {
            if match.isVetoed { throw Self.refusal("P0001", "the host passed on that place", "FC_VETOED") }
            return match
        }
        try checkCaps(plan: proposalID, suggester: me)

        let saved = Place(id: UUID(), proposalID: proposalID, suggestedBy: me, name: normalized.name, address: normalized.address,
                          latitude: normalized.latitude, longitude: normalized.longitude, mapRef: normalized.mapRef,
                          vetoedAt: nil, createdAt: now())
        places.append(saved)
        emit(proposalID)
        return saved
    }

    public func votePlace(proposalID: UUID, placeID: UUID?) async throws {
        let me = try await authorize(.votePlace)
        applyStaleChange(proposalID: proposalID, placeID: placeID)
        _ = try placePlan(proposalID, as: me)
        guard let placeID else {
            votes.removeAll { $0.proposalID == proposalID && $0.voterID == me }
            emit(proposalID)
            return
        }
        guard let place = places.first(where: { $0.id == placeID && $0.proposalID == proposalID }) else {
            throw Self.refusal("P0002", "that place is not on this plan", "FC_PLACE_NOT_FOUND")
        }
        if place.isVetoed { throw Self.refusal("P0001", "the host passed on that place", "FC_VETOED") }
        if place.suggestedBy == me { throw Self.refusal("42501", "you cannot vote for your own suggestion", "FC_OWN_PLACE") }
        // Moving a vote rewrites its time; repeating the same vote changes nothing, because the order of
        // voters on a row depends on it.
        if let index = votes.firstIndex(where: { $0.proposalID == proposalID && $0.voterID == me }) {
            guard votes[index].placeID != placeID else { return }
            votes[index].placeID = placeID
            votes[index].createdAt = now()
        } else {
            votes.append(PlaceVote(proposalID: proposalID, voterID: me, placeID: placeID, createdAt: now()))
        }
        emit(proposalID)
    }

    public func vetoPlace(placeID: UUID, vetoed: Bool) async throws -> Place {
        let me = try await authorize(.vetoPlace)
        // An unknown place id becomes a nil plan id, which raises the same FC_NOT_FOUND as an excluded
        // caller: a distinct "place not found" would let an excluded caller tell a real id from a fake one.
        let planID = places.first { $0.id == placeID }?.proposalID
        let (_, plan) = try placePlan(planID, as: me)
        guard let index = places.firstIndex(where: { $0.id == placeID }) else { throw Self.refusal("P0002", "no such plan", "FC_NOT_FOUND") }
        guard plan.createdBy == me else { throw Self.refusal("42501", "only the host can pass on a place", "FC_NOT_CREATOR") }
        if vetoed {
            if places[index].vetoedAt == nil {
                places[index].vetoedAt = now()
                votes.removeAll { $0.placeID == placeID }
            }
        } else if places[index].vetoedAt != nil {
            // Bring it back as if it were being added now: the caps count active places only.
            try checkCaps(plan: places[index].proposalID, suggester: places[index].suggestedBy)
            places[index].vetoedAt = nil
        }
        emit(places[index].proposalID)
        return places[index]
    }

    public func removePlace(placeID: UUID) async throws {
        let me = try await authorize(.removePlace)
        let planID = places.first { $0.id == placeID }?.proposalID
        _ = try placePlan(planID, as: me)
        guard let index = places.firstIndex(where: { $0.id == placeID }) else { throw Self.refusal("P0002", "no such plan", "FC_NOT_FOUND") }
        guard places[index].suggestedBy == me else {
            throw Self.refusal("42501", "only the person who suggested a place can remove it", "FC_NOT_YOUR_PLACE")
        }
        // A place the host passed on stays: the vetoed row is what refuses a re-suggestion, so
        // deleting it would let the same place come back as an active one.
        guard places[index].vetoedAt == nil else { throw Self.refusal("P0001", "the host passed on that place", "FC_VETOED") }
        let plan = places[index].proposalID
        places.remove(at: index)
        votes.removeAll { $0.placeID == placeID }
        emit(plan)
    }

    // MARK: Poke and Tag along (social.sql's contract, check for check)

    private func isActive(_ id: UUID) -> Bool { users.contains { $0.id == id } && !deletedUserIDs.contains(id) }

    /// friendcal_share_plan(): a plan neither is hidden from, with both on it, not cancelled.
    private func sharePlan(_ a: UUID, _ b: UUID) -> Bool {
        proposals.contains { $0.status != .cancelled && $0.isReadable(by: a) && $0.isReadable(by: b) }
    }

    private func displayName(_ id: UUID) -> String {
        let name = users.first { $0.id == id }?.displayName.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? SocialInbox.unknownName : name
    }

    public func sendPoke(to userID: UUID, about proposalID: UUID?) async throws -> PokeReceipt {
        let me = try await authorize(.sendPoke)
        guard !deletedUserIDs.contains(me) else {
            throw Self.refusal("42501", "this account has been deleted", "FC_ACCOUNT_DELETED")
        }
        guard userID != me else { throw Self.refusal("22023", "you cannot poke yourself", "FC_SELF_POKE") }
        guard isActive(userID), areFriends(me, userID) || sharePlan(me, userID) else {
            throw Self.refusal("P0002", "you can only poke friends", "FC_NOT_FRIEND")
        }
        let at = now()
        if let live = pokes.last(where: { $0.fromID == me && $0.toID == userID && $0.isLive(at: at) }) {
            return PokeReceipt(poke: live, isNew: false)
        }
        // The plan is context, never authorization: unreadable by either person, it is dropped.
        let plan = proposalID.flatMap { id in
            proposals.first { $0.id == id && $0.status != .cancelled && $0.isReadable(by: me) && $0.isReadable(by: userID) }
        }
        for i in pokes.indices where pokes[i].fromID == userID && pokes[i].toID == me && pokes[i].isLive(at: at) {
            pokes[i].acknowledgedAt = at
            pokes[i].ackVia = .pokeBack
        }
        let poke = Poke(fromID: me, toID: userID, proposalID: plan?.id, createdAt: at)
        pokes.append(poke)
        let body = plan.map { "About \($0.title). Poke back before it fades in an hour." } ?? "Poke back before it fades in an hour."
        outbox.append(QueuedPush(recipientID: userID, kind: .poke, title: "\(displayName(me)) poked you", body: body,
                                 route: .poke(poke.id), expiresAt: poke.expiresAt))
        return PokeReceipt(poke: poke, isNew: true)
    }

    public func acknowledgePoke(_ id: UUID, via: Poke.AckVia) async throws -> Poke {
        let me = try await authorize(.acknowledgePoke)
        guard let index = pokes.firstIndex(where: { $0.id == id && $0.toID == me }) else {
            throw Self.refusal("P0002", "no such poke", "FC_POKE_NOT_FOUND")
        }
        if pokes[index].isLive(at: now()) {
            pokes[index].acknowledgedAt = now()
            pokes[index].ackVia = via == .push ? .push : .app
        }
        return pokes[index]
    }

    public func tagAlong(_ proposalID: UUID) async throws -> Proposal {
        let me = try await authorize(.tagAlong)
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }), !proposals[index].hiddenFrom.contains(me) else {
            throw Self.refusal("P0002", "no such plan", "FC_NOT_FOUND")
        }
        guard !deletedUserIDs.contains(me) else {
            throw Self.refusal("42501", "this account has been deleted", "FC_ACCOUNT_DELETED")
        }
        var p = proposals[index]
        switch TagAlongRules.refusal(p, user: me, now: now()) {
        case .notFound: throw Self.refusal("P0002", "no such plan", "FC_NOT_FOUND")
        case .notLocked: throw Self.refusal("55000", "this plan is not locked yet", "FC_NOT_LOCKED")
        case .closed: throw Self.refusal("55000", "this plan is \(p.status.rawValue), not open to join", "FC_CLOSED")
        case .over: throw Self.refusal("55000", "this plan is over", "FC_PLAN_OVER")
        case .alreadyIn: return p
        case nil: break
        }
        guard let window = p.lockedWindow else { throw Self.refusal("55000", "this plan is over", "FC_PLAN_OVER") }
        // busy_blocks' exclusion constraint: no two hard Busy blocks of one person may overlap.
        guard !busyBlocks.contains(where: { $0.userID == me && $0.range.overlaps(window) }) else {
            throw Self.refusal("23P01", "you are already busy then", "FC_BUSY")
        }
        ensureUser(me)
        busyBlocks.append(BusyBlock(userID: me, range: window, visibility: .public, hiddenFrom: [], sourceProposalID: p.id, createdAt: now()))
        if !p.distribution.recipientIDs.contains(me) { p.distribution.recipientIDs.append(me) }
        p.lockedAttendeeIDs.append(me)
        proposals[index] = p
        if !tagAlongs.contains(where: { $0.proposalID == p.id && $0.userID == me }) {
            tagAlongs.append(TagAlong(proposalID: p.id, userID: me, createdAt: now()))
        }
        if p.createdBy != me, isActive(p.createdBy) {
            outbox.append(QueuedPush(recipientID: p.createdBy, kind: .tagAlong, title: "\(displayName(me)) is tagging along",
                                     body: "They just joined \(p.title).", route: .tagAlong(proposalID: p.id), expiresAt: window.upperBound))
        }
        emit(p.id)
        return p
    }

    public func inbox() async throws -> SocialInbox {
        let me = try await authorize(.inbox)
        let mine = pokes.filter { $0.fromID == me || $0.toID == me }
        let notices = tagAlongs.compactMap { row -> TagAlongNotice? in
            guard let plan = proposals.first(where: { $0.id == row.proposalID }), plan.createdBy == me, plan.isReadable(by: me) else { return nil }
            return TagAlongNotice(proposalID: row.proposalID, userID: row.userID, planTitle: plan.title, createdAt: row.createdAt)
        }
        let people = Set(mine.flatMap { [$0.fromID, $0.toID] } + notices.map(\.userID))
        var titles: [UUID: String] = [:]
        for id in Set(mine.compactMap(\.proposalID)) {
            if let plan = proposals.first(where: { $0.id == id }), plan.isReadable(by: me) { titles[id] = plan.title }
        }
        return SocialInbox(pokes: mine, tagAlongs: notices,
                           names: Dictionary(uniqueKeysWithValues: people.map { ($0, displayName($0)) }), planTitles: titles)
    }

    public func registerDevice(token: String, sandbox: Bool) async throws {
        let me = try await authorize(.registerDevice)
        let hex = token.lowercased()
        guard (32...200).contains(hex.count), hex.allSatisfy({ $0.isHexDigit }) else {
            throw Self.refusal("22023", "not a device token", "FC_BAD_TOKEN")
        }
        deviceTokens[hex] = me
    }

    /// Fixtures and tests: pokes that arrived (or went out) before the screen opened.
    public func seed(pokes: [Poke], tagAlongs: [TagAlong] = []) {
        self.pokes = pokes
        self.tagAlongs = tagAlongs
    }

    // MARK: Add a friend (friends.sql's contract, check for check)

    private func areFriends(_ a: UUID, _ b: UUID) -> Bool { friendships[FriendPair(a, b)] != nil }

    /// Fixtures and tests: makes these people the caller's friends, as the demo roster is.
    public func befriend(_ ids: some Sequence<UUID>, with me: UUID, at date: Date? = nil) {
        for id in ids where id != me { friendships[FriendPair(me, id)] = friendships[FriendPair(me, id)] ?? (date ?? now()) }
    }

    /// Tests: sets a person's link record, to reach the cap without fifty accepts.
    public func setFriendLinkRecord(_ record: FriendLinkRecord, for user: UUID) { friendLinks[user] = record }

    /// Makes the current person's friends exactly `ids` (demo data aligned to a Groups scenario).
    public func setFriends(_ ids: some Sequence<UUID>, of me: UUID) {
        friendships = friendships.filter { $0.key.other(than: me) == nil }
        befriend(ids, with: me)
    }

    private func requireActive(_ me: UUID) throws {
        guard isActive(me) || !users.contains(where: { $0.id == me }) else {
            throw Self.refusal("42501", "this account has been deleted", "FC_ACCOUNT_DELETED")
        }
    }

    private static func newToken() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<FriendToken.length).map { _ in alphabet.randomElement()! })
    }

    public func friendLink() async throws -> String {
        let me = try await authorize(.friendLink)
        try requireActive(me)
        if let record = friendLinks[me] { return record.token }
        ensureUser(me)
        let record = FriendLinkRecord(token: Self.newToken())
        friendLinks[me] = record
        return record.token
    }

    public func resetFriendLink() async throws -> String {
        let me = try await authorize(.resetFriendLink)
        try requireActive(me)
        ensureUser(me)
        var record = friendLinks[me] ?? FriendLinkRecord(token: "", mintCount: 0)
        record.token = Self.newToken()
        record.tokenAccepts = 0
        record.mintCount += 1
        friendLinks[me] = record
        return record.token
    }

    /// friendcal_friend_link_answer(): the order of the tests is the spec's.
    private func linkAnswer(_ token: String, caller me: UUID) -> (FriendLinkAnswer.Status, UUID?) {
        if let scenario = friendLinkScenario {
            let inviter = Self.scenarioInviterID
            if !users.contains(where: { $0.id == inviter }) { users.append(User(id: inviter, displayName: "Sam")) }
            switch scenario {
            case .dead: return (.dead, nil)
            case .own: return (.own, me)
            case .already: return (.already, inviter)
            case .valid: return areFriends(me, inviter) ? (.already, inviter) : (.valid, inviter)
            }
        }
        guard FriendToken.isValid(token), let (owner, record) = friendLinks.first(where: { $0.value.token == token }), isActive(owner) else {
            return (.dead, nil)
        }
        if owner == me { return (.own, owner) }
        if friendRemovals.contains(FriendRemoval(remover: owner, removed: me)) { return (.dead, nil) }
        if areFriends(me, owner) { return (.already, owner) }
        if record.tokenAccepts >= Self.friendLinkCap { return (.dead, nil) }
        return (.valid, owner)
    }

    private func answer(_ status: FriendLinkAnswer.Status, _ person: UUID?) -> FriendLinkAnswer {
        switch status {
        case .valid, .already:
            guard let person else { return .dead }
            let user = users.first { $0.id == person }
            return FriendLinkAnswer(status: status, person: Friend(id: person, name: user?.displayName ?? "", avatarURL: user?.avatarURL))
        case .own: return .own
        case .dead: return .dead
        }
    }

    public func previewFriendLink(token: String) async throws -> FriendLinkAnswer {
        let me = try await authorize(.previewFriendLink)
        try requireActive(me)
        let (status, person) = linkAnswer(token, caller: me)
        return answer(status, person)
    }

    public func acceptFriendLink(token: String) async throws -> FriendLinkAnswer {
        let me = try await authorize(.acceptFriendLink)
        try requireActive(me)
        let (status, person) = linkAnswer(token, caller: me)
        guard status == .valid, let inviter = person else { return answer(status, person) }
        ensureUser(me)
        friendships[FriendPair(me, inviter)] = now()
        if var record = friendLinks[inviter], friendLinkScenario == nil {
            record.tokenAccepts += 1
            record.acceptCount += 1
            friendLinks[inviter] = record
        }
        friendRemovals.remove(FriendRemoval(remover: me, removed: inviter))
        if isActive(inviter) {
            outbox.append(QueuedPush(recipientID: inviter, kind: .friendJoined, title: "\(displayName(me)) connected with you",
                                     body: "You two are connected.", route: nil, expiresAt: now().addingTimeInterval(24 * 3600)))
        }
        return answer(.valid, inviter)
    }

    public func friends() async throws -> [Friend] {
        let me = try await authorize(.friends)
        try requireActive(me)
        return friendships.compactMap { pair, since -> Friend? in
            guard let other = pair.other(than: me), isActive(other) else { return nil }
            let user = users.first { $0.id == other }
            return Friend(id: other, name: user?.displayName ?? "", avatarURL: user?.avatarURL, connectedAt: since)
        }
        .sorted { ($0.connectedAt ?? .distantPast, $1.id.uuidString) > ($1.connectedAt ?? .distantPast, $0.id.uuidString) }
    }

    public func removeFriend(_ userID: UUID) async throws {
        let me = try await authorize(.removeFriend)
        try requireActive(me)
        guard userID != me, friendships.removeValue(forKey: FriendPair(me, userID)) != nil else { return }
        friendRemovals.insert(FriendRemoval(remover: me, removed: userID))
    }

    /// Demo and UI tests: `name` opens the current person's link and connects, as if on another phone.
    /// Returns the new friend's id.
    @discardableResult
    public func simulateFriendAccepting(named name: String) -> UUID? {
        guard let me = currentUserID else { return nil }
        let guest = User(id: UUID(), displayName: name)
        users.append(guest)
        friendships[FriendPair(me, guest.id)] = now()
        if var record = friendLinks[me] { record.tokenAccepts += 1; record.acceptCount += 1; friendLinks[me] = record }
        outbox.append(QueuedPush(recipientID: me, kind: .friendJoined, title: "\(name) connected with you",
                                 body: "You two are connected.", route: nil, expiresAt: now().addingTimeInterval(24 * 3600)))
        return guest.id
    }

    public func tapFree(proposalID: UUID, range: DateRange, expiresAt: Date?) async throws -> AvailabilitySlot {
        let me = try await authorize(.tapFree)
        guard let p = proposals.first(where: { $0.id == proposalID }) else { throw ProposalStoreError.notFound(proposalID) }
        // D15: a hold needs a recipient, an open plan and a range inside its window.
        guard p.isRecipient(me) else {
            throw ProposalStoreError.server(code: "42501", message: "not a recipient of this proposal", hint: "FC_NOT_MEMBER")
        }
        guard p.status == .requesting else {
            throw ProposalStoreError.server(code: "55000", message: "proposal is \(p.status.rawValue), not requesting", hint: "FC_LOCKED")
        }
        guard p.window.lowerBound <= range.lowerBound, range.upperBound <= p.window.upperBound, range.lowerBound < range.upperBound else {
            throw ProposalStoreError.server(code: "22023", message: "hold must sit inside the proposal window", hint: "FC_WINDOW")
        }
        switch availability.tapFreeSlot(userID: me, range: range, proposalID: proposalID, expiresAt: expiresAt, existingSlots: ownSlots(of: me), now: now()) {
        case .alreadyHeld:
            throw ProposalStoreError.heldElsewhere
        case .softHold(var slot):
            slot.createdAt = now()
            slots.append(slot)
            emit(proposalID)
            return slot
        }
    }

    public func release(slotID: UUID) async throws {
        let me = try await authorize(.release)
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { throw ProposalStoreError.notFound(slotID) }
        let slot = slots[index]
        guard slot.userID == me else {
            throw ProposalStoreError.server(code: "42501", message: "not your hold", hint: "FC_NOT_OWNER")
        }
        slots.remove(at: index)
        if let pid = slot.sourceProposalID { emit(pid) }
    }

    /// Mirrors lock_proposal.sql: creator only, requesting only, a >= 60-min window inside the plan,
    /// at least 2 recipients, quorum over max(expected, joined) counting a recipient when their
    /// merged unexpired holds cover the window and no Busy block of theirs overlaps it; then one
    /// transaction: status + both ends + attendees, Busy blocks, holds cleared.
    public func lock(_ id: UUID, window: DateRange) async throws -> Proposal {
        let me = try await authorize(.lock)
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { throw ProposalStoreError.notFound(id) }
        var p = proposals[index]
        guard p.createdBy == me else {
            throw ProposalStoreError.server(code: "42501", message: "only the proposal creator can lock it", hint: "FC_NOT_CREATOR")
        }
        guard p.status == .requesting else {
            throw ProposalStoreError.server(code: "55000", message: "proposal is \(p.status.rawValue), not requesting", hint: "FC_LOCKED")
        }
        guard window.upperBound.timeIntervalSince(window.lowerBound) >= HeatmapBuilder.minimumCommonDuration,
              window.lowerBound >= p.window.lowerBound, window.upperBound <= p.window.upperBound else {
            throw ProposalStoreError.server(code: "22023", message: "lock window must be at least 60 minutes inside the proposal window", hint: "FC_WINDOW")
        }
        let recipients = p.joinedIDs
        guard recipients.count >= 2 else {
            throw ProposalStoreError.server(code: "22023", message: "no recipients to lock", hint: "FC_NO_RECIPIENTS")
        }
        let at = now()
        let total = p.headcount
        var (promoted, cleared) = availability.promoteToBusy(window: window, proposalID: id, recipientIDs: recipients, slots: slots, now: at)
        // Busy recipients neither count nor block (lock_proposal.sql).
        promoted.removeAll { block in busyBlocks.contains { $0.userID == block.userID && $0.range.intersects(window) } }
        let free = promoted.count
        guard Double(free) / Double(total) >= ProposalService.quorumThreshold else {
            let need = Int((ProposalService.quorumThreshold * 100).rounded()), have = Int((Double(free) * 100 / Double(total)).rounded())
            throw ProposalStoreError.server(code: "22023", message: "need \(need) percent free, only \(have) percent", hint: "FC_QUORUM")
        }
        ProposalService.apply(window: window, to: &p, attendees: promoted.map(\.userID), at: at)
        // The winner is chosen by the one rule and stored in the same mutation as the status
        // (friendcal_place_winner in places.sql); nil when no non-vetoed place has a vote.
        p.lockedPlaceID = PlaceBoard.winner(places: places.filter { $0.proposalID == id }, votes: votes.filter { $0.proposalID == id })
        proposals[index] = p
        slots.removeAll { cleared.contains($0.id) }
        busyBlocks.append(contentsOf: promoted)
        emit(id)
        return p
    }

    public func changes(for id: UUID) -> AsyncStream<ProposalChange> {
        let token = UUID()
        return AsyncStream { continuation in
            lock.withLock { continuations[id, default: [:]][token] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.continuations[id]?.removeValue(forKey: token) }
            }
        }
    }

    // MARK: Busy reads (from MockSupabaseService; StealthTests)

    /// The sanitized read: an excluded viewer gets a plain Busy block with `hiddenFrom` stripped.
    public func fetchBusyBlocks(for viewerID: UUID, in range: DateRange) async throws -> [BusyBlock] {
        // Blanked unconditionally, through the one named site. Blanking only for the excluded viewer
        // would leave the shape viewer-dependent, which is itself the correlation signal, and would
        // be a third hand-maintained field list. `BusyBlock.sanitized` is the only place that knows
        // which fields are safe.
        busyBlocks.filter { $0.range.overlaps(range) }.map(\.sanitized)
    }

    // MARK: Seeding

    /// Replaces the seeded rows (fixtures, previews).
    public func seed(users: [User], proposals: [Proposal], slots: [AvailabilitySlot], busyBlocks: [BusyBlock] = [], places: [Place] = [], votes: [PlaceVote] = [], currentUserID: UUID?) {
        self.users = users
        self.proposals = proposals
        self.slots = slots
        self.busyBlocks = busyBlocks
        self.places = places
        self.votes = votes
        self.currentUserID = currentUserID
    }

    /// Removes a proposal and its rows ("This plan is gone" paths).
    public func remove(proposalID: UUID) {
        proposals.removeAll { $0.id == proposalID }
        slots.removeAll { $0.sourceProposalID == proposalID }
        places.removeAll { $0.proposalID == proposalID }
        votes.removeAll { $0.proposalID == proposalID }
        emit(proposalID)
    }

    /// Synchronous read for seeding a session before any await.
    public func snapshot(of id: UUID) throws -> ProposalSnapshot {
        guard let p = proposals.first(where: { $0.id == id }) else { throw ProposalStoreError.notFound(id) }
        let members = p.joinedIDs.map { uid in users.first { $0.id == uid } ?? User(id: uid, displayName: "Friend") }
        return ProposalSnapshot(proposal: p, members: members, slots: slots.filter { $0.sourceProposalID == id },
                                places: places.filter { $0.proposalID == id }, votes: votes.filter { $0.proposalID == id })
    }

    // MARK: Private

    /// `try await`, not `try?`. Swallowing the sleep's error swallows `CancellationError`, so an
    /// operation whose task was cancelled -- a screen dismissed, a sign-out mid-flight -- would carry
    /// on and commit its write anyway. Cancellation has to propagate out of here for the identity
    /// generation check in the callers to ever matter (outside voice F6).
    private func gate(_ op: Operation) async throws {
        if latency > .zero { try await Task.sleep(for: latency) }
        try Task.checkCancellation()
        if let error = failNext.removeValue(forKey: op) { throw error }
    }

    /// Publishes a new auth state, bumping the identity generation when the IDENTITY changed.
    ///
    /// `.signingIn` and `.failed` do not bump: they are the same identity (none) in a different
    /// presentation, and bumping on them would cancel in-flight work that has nothing to do with
    /// them. Only a sign-in, a sign-out or a deletion moves the generation.
    private func setAuth(_ state: AuthState, bumpGeneration: Bool) {
        if bumpGeneration { identityGeneration += 1 }
        authState = state
        let targets = lock.withLock { Array(authContinuations.values) }
        for continuation in targets { continuation.yield(state) }
    }

    /// Capture the identity, suspend, then re-check it. Every operation goes through here.
    ///
    /// The ordering is the whole point and it is easy to get wrong: read the identity BEFORE the
    /// await, and compare it again AFTER. An operation that reads `currentUserID` only after
    /// suspending silently adopts whoever is signed in when it resumes, so a tap made by A that
    /// suspends across a sign-out and a sign-in as B commits as B. Checking both the generation and
    /// the id covers the case where the same person signs back in: the generation moved even though
    /// the id matches, and work begun in the previous session should still not land.
    private func authorize(_ op: Operation) async throws -> UUID {
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
        let generation = identityGeneration
        try await gate(op)
        guard identityGeneration == generation, currentUserID == me else {
            throw ProposalStoreError.identityChanged
        }
        return me
    }

    private func ensureUser(_ id: UUID) {
        if !users.contains(where: { $0.id == id }) { users.append(User(id: id, displayName: "You")) }
    }

    /// The caller's own time as SLOTS, for the tap-free collision check.
    ///
    /// Deliberately separate from `commitments(of:)`, which answers a different question. This one
    /// feeds `AvailabilityService.tapFreeSlot`, a UX guard that asks "does this clash with anything I
    /// already hold?" and needs `AvailabilityState` to tell a hard Busy from a soft hold. It includes
    /// `.free` rows and carries no titles, because neither matters to a clash. Collapsing the two
    /// into one function would mean either the guard loses the state it switches on, or the screen
    /// gains rows it must not show.
    private func ownSlots(of user: UUID) -> [AvailabilitySlot] {
        slots.filter { $0.userID == user } + busyBlocks.filter { $0.userID == user }.map {
            AvailabilitySlot(id: $0.id, userID: $0.userID, range: $0.range, sourceProposalID: nil, state: .busy, createdAt: $0.createdAt)
        }
    }

    /// The caller's commitments, with provenance preserved and titles authorized per row.
    ///
    /// Provenance used to be thrown away here -- Busy blocks were mapped to slots with
    /// `sourceProposalID: nil` -- which made it impossible for any screen to say WHICH plan had taken
    /// the time. That is the whole content of the commitments screen, so the nil was the feature's
    /// absence rather than a detail.
    ///
    /// The title goes through `isReadable(by:)`, the Swift mirror of the SQL predicate, so the
    /// in-memory store withholds exactly the names the server would withhold. A block from a plan the
    /// viewer may not read still appears -- their time really is taken -- with `planTitle` nil.
    private func commitments(of user: UUID) -> [Commitment] {
        func title(forPlan id: UUID?) -> String? {
            guard let id, let plan = proposals.first(where: { $0.id == id }) else { return nil }
            return plan.isReadable(by: user) ? plan.displayTitle : nil
        }

        let holds = slots
            .filter { $0.userID == user && $0.state == .softHold }
            .map { slot in
                Commitment(id: slot.id, kind: .held, range: slot.range,
                           sourceProposalID: slot.sourceProposalID,
                           planTitle: title(forPlan: slot.sourceProposalID),
                           expiresAt: slot.expiresAt)
            }

        let blocks = busyBlocks
            .filter { $0.userID == user }
            .map { block in
                Commitment(id: block.id,
                           kind: block.sourceProposalID == nil ? .busy : .locked,
                           range: block.range,
                           sourceProposalID: block.sourceProposalID,
                           planTitle: title(forPlan: block.sourceProposalID),
                           expiresAt: nil)
            }

        return holds + blocks
    }

    private func emit(_ id: UUID) {
        let targets = lock.withLock { Array(continuations[id]?.values ?? [:].values) }
        guard !targets.isEmpty else { return }
        if let snap = try? snapshot(of: id) {
            for c in targets { c.yield(.snapshot(snap)) }
        } else {
            for c in targets { c.finish() }
        }
    }
}
