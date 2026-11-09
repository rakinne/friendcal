import Foundation
import Supabase

/// What the sign-in screen needs from a store that signs in with Apple. The in-memory store does not
/// conform, so the gate keeps its name field for demo data and UI tests.
@MainActor
public protocol AppleSignInCapable: AnyObject {
    /// `idToken` and `nonce` come from `ASAuthorizationAppleIDCredential`; `nonce` is the RAW nonce
    /// (its SHA-256 went to Apple). `displayName` is Apple's full name, which Apple sends only on the
    /// first authorization of an app, so it is nil on every later one.
    func signInWithApple(idToken: String, nonce: String, displayName: String?) async throws -> UUID
}

/// The network `ProposalStore` (issue #5 PR2, #14): Supabase Auth with Sign in with Apple, PostgREST
/// reads under RLS, and the server's RPCs for every rule that must not be the client's call.
///
/// It is server-first like the in-memory store it mirrors: no optimistic updates, every mutation
/// awaits the server and then pushes a fresh snapshot to anyone watching that plan. Refusals arrive
/// as `PostgrestError` and leave as `ProposalStoreError.server(code:message:hint:)`, so
/// `UserFacingError` maps them without knowing which store it is talking to.
///
/// `changes(for:)` polls. Realtime needs the tables in the publication and a channel per plan; polling
/// needs nothing from the dashboard, so two phones can be tested today. Mutations nudge watchers
/// immediately, so the person who acted never waits for the next tick.
@MainActor
public final class SupabaseProposalStore: ProposalStore, AppleSignInCapable {
    public private(set) var currentUserID: UUID?
    public private(set) var authState: AuthState = .signedOut
    public private(set) var identityGeneration: Int = 0

    /// How often an open plan re-reads the server.
    public var pollInterval: Duration

    nonisolated(unsafe) private var authContinuations: [UUID: AsyncStream<AuthState>.Continuation] = [:]
    private let authLock = NSLock()
    private var watchers: [UUID: [UUID: Watcher]] = [:]
    private let client: SupabaseClient
    private let availability = AvailabilityService()

    private final class Watcher {
        let continuation: AsyncStream<ProposalChange>.Continuation
        var last: ProposalSnapshot?
        init(_ continuation: AsyncStream<ProposalChange>.Continuation) { self.continuation = continuation }
    }

    public init(url: URL, anonKey: String, pollInterval: Duration = .seconds(4)) {
        self.pollInterval = pollInterval
        self.client = SupabaseClient(
            supabaseURL: url, supabaseKey: anonKey,
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true)))
        // A session kept from a previous launch starts the app signed in; an expired access token
        // is refreshed by the first request.
        if let session = client.auth.currentSession {
            currentUserID = session.user.id
            authState = .signedIn(session.user.id)
        }
    }

    /// Reads `SupabaseURL` and `SupabaseAnonKey` from Info.plist, which the build fills from
    /// `Config/Local.xcconfig`. Nil when either is missing or still an unexpanded `$(...)`.
    public static func fromBundle(_ bundle: Bundle = .main) -> SupabaseProposalStore? {
        guard let urlText = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              let key = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
              !urlText.isEmpty, !key.isEmpty, !urlText.contains("$("), !key.contains("$("),
              let url = URL(string: urlText), url.scheme == "https" else { return nil }
        return SupabaseProposalStore(url: url, anonKey: key)
    }

    // MARK: Auth

    public var authChanges: AsyncStream<AuthState> {
        let token = UUID()
        return AsyncStream { continuation in
            authLock.withLock { authContinuations[token] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.authLock.withLock { _ = self.authContinuations.removeValue(forKey: token) }
            }
        }
    }

    private func setAuth(_ state: AuthState, bumpGeneration: Bool) {
        if bumpGeneration { identityGeneration += 1 }
        authState = state
        let targets = authLock.withLock { Array(authContinuations.values) }
        for continuation in targets { continuation.yield(state) }
    }

    /// Apple is the only network sign-in; the in-memory store keeps the name-only one.
    public func signIn(displayName: String?) async throws -> UUID {
        if let id = currentUserID { return id }
        let error = ProposalStoreError.server(code: "28000", message: "Sign in with Apple is required", hint: "FC_NOT_SIGNED_IN")
        setAuth(.failed(UserFacingError.map(error, action: .signIn)), bumpGeneration: false)
        throw error
    }

    public func signInWithApple(idToken: String, nonce: String, displayName: String?) async throws -> UUID {
        if let id = currentUserID { return id }
        setAuth(.signingIn, bumpGeneration: false)
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
            let id = session.user.id
            try await ensureUserRow(id, displayName: displayName)
            currentUserID = id
            setAuth(.signedIn(id), bumpGeneration: true)
            return id
        } catch {
            let mapped = Self.map(error)
            // Do not leave a half-made session behind when the profile step was refused.
            try? await client.auth.signOut(scope: .local)
            setAuth(.failed(UserFacingError.map(mapped, action: .signIn)), bumpGeneration: false)
            throw mapped
        }
    }

    public func signOut() async {
        try? await client.auth.signOut(scope: .local)
        stopWatching()
        currentUserID = nil
        setAuth(.signedOut, bumpGeneration: true)
    }

    public func deleteAccount() async throws -> AccountDeletionReceipt {
        try await perform { _ in
            let r: DeletionRow = try await self.client.rpc("delete_account").execute().value
            return AccountDeletionReceipt(alreadyDeleted: r.alreadyDeleted, cancelledPlans: r.cancelledPlans,
                                          releasedHolds: r.releasedHolds, lockedPlansKept: r.lockedPlansKept)
        } finish: { [self] _ in
            try? await client.auth.signOut(scope: .local)
            stopWatching()
            currentUserID = nil
            setAuth(.signedOut, bumpGeneration: true)
        }
    }

    /// The `users` row is the app's profile; `auth.users` is Supabase's. Created on first sign-in
    /// with Apple's name when it sent one, "Friend" otherwise, and never overwritten by a later
    /// sign-in unless it still holds the placeholder.
    private func ensureUserRow(_ id: UUID, displayName: String?) async throws {
        let name = PlaceText.trimmedOrNil(displayName)
        let rows: [UserRow] = try await client.from("users").select(Self.userColumns)
            .eq("id", value: id.uuidString).limit(1).execute().value
        if let row = rows.first {
            if row.deletedAt != nil {
                throw ProposalStoreError.server(code: "42501", message: "this account has been deleted", hint: "FC_ACCOUNT_DELETED")
            }
            if row.displayName == Self.placeholderName, let name {
                try await client.from("users").update(["display_name": name]).eq("id", value: id.uuidString).execute()
            }
        } else {
            try await client.from("users")
                .insert(UserInsert(id: id, displayName: name ?? Self.placeholderName)).execute()
        }
    }

    private static let placeholderName = "Friend"
    private static let userColumns = "id,display_name,avatar_url,deleted_at"

    // MARK: Reads

    public func proposals() async throws -> [ProposalSummary] {
        try await perform { me in
            let rows: [ProposalRow] = try await self.client.from("proposals").select(Self.proposalColumns)
                .order("created_at", ascending: false).execute().value
            return rows.map(\.model)
                .filter { $0.createdBy == me || $0.isRecipient(me) }
                .map { ProposalSummary(proposal: $0, joinedCount: $0.joinedCount, isHosting: $0.createdBy == me) }
        }
    }

    public func load(_ id: UUID) async throws -> ProposalSnapshot {
        try await perform { _ in try await self.fetchSnapshot(id) }
    }

    private func fetchSnapshot(_ id: UUID) async throws -> ProposalSnapshot {
        let proposal = try await fetchProposal(id)
        let memberIDs = HeatmapBuilder.distinct([proposal.createdBy] + proposal.distribution.recipientIDs)
        async let users: [UserRow] = client.from("users").select(Self.userColumns)
            .in("id", values: memberIDs.map(\.uuidString)).execute().value
        async let slots: [SlotRow] = client.from("availability_slots").select(Self.slotColumns)
            .eq("source_proposal_id", value: id.uuidString).execute().value
        async let places: [PlaceRow] = client.from("proposal_places").select()
            .eq("proposal_id", value: id.uuidString).order("created_at").execute().value
        async let votes: [VoteRow] = client.from("place_votes").select()
            .eq("proposal_id", value: id.uuidString).execute().value
        let found = try await users
        // Everyone on the plan, in join order. A member the server will not show us still gets a seat.
        let members = proposal.joinedIDs.map { uid in
            found.first { $0.id == uid }?.model ?? User(id: uid, displayName: Self.placeholderName)
        }
        return ProposalSnapshot(proposal: proposal, members: members,
                                slots: try await slots.map(\.model), places: try await places.map(\.model),
                                votes: try await votes.map(\.model))
    }

    private func fetchProposal(_ id: UUID) async throws -> Proposal {
        let rows: [ProposalRow] = try await client.from("proposals").select(Self.proposalColumns)
            .eq("id", value: id.uuidString).limit(1).execute().value
        guard let row = rows.first else { throw ProposalStoreError.notFound(id) }
        return row.model
    }

    public func myCommitments(from: Date) async throws -> [Commitment] {
        try await perform { _ in
            let rows: [CommitmentRow] = try await self.client.rpc("my_commitments", params: FromParam(p_from: from)).execute().value
            return rows.compactMap(\.model)
        }
    }

    // MARK: Proposals

    public func create(_ plan: NewProposal) async throws -> Proposal {
        try await perform { me in
            if let area = plan.area, !area.isValid { throw Self.badCity() }
            let id = UUID()
            let row = ProposalInsert(
                id: id, title: plan.title, windowStart: plan.window.lowerBound, windowEnd: plan.window.upperBound,
                createdBy: me, status: "requesting",
                distribution: DistributionJSON(mode: DistributionMode.newGroup.rawValue, recipientIDs: [me], expectedCount: plan.expectedCount),
                areaName: plan.area?.name, areaLat: plan.area?.latitude, areaLon: plan.area?.longitude)
            // No `.select()` on the insert: RETURNING needs the read policy and grants to line up for a
            // row the server has not finished writing. A second read is one extra round trip, once.
            try await self.client.from("proposals").insert(row).execute()
            return try await self.fetchProposal(id)
        }
    }

    public func update(_ edited: Proposal) async throws -> Proposal {
        try await perform { _ in
            let current = try await self.fetchProposal(edited.id)
            // `distribution` and the window are server-owned (proposals_edit_guard), and no RPC edits
            // them yet, so say so instead of reporting a save that did nothing.
            if edited.window != current.window || edited.expectedCount != current.expectedCount {
                throw ProposalStoreError.server(
                    code: "0A000", message: "editing the dates or headcount of a plan is not available yet", hint: "FC_NOT_SUPPORTED")
            }
            if let area = edited.area, !area.isValid { throw Self.badCity() }
            if current.area != nil, edited.area == nil {
                throw ProposalStoreError.server(code: "22023", message: "a plan keeps its city; replace it instead of clearing it", hint: "FC_AREA_REQUIRED")
            }
            let rows: [ProposalRow] = try await self.client.from("proposals")
                .update(ProposalUpdate(title: edited.title, areaName: edited.area?.name,
                                       areaLat: edited.area?.latitude, areaLon: edited.area?.longitude))
                .eq("id", value: edited.id.uuidString).select(Self.proposalColumns).execute().value
            guard let row = rows.first else { throw ProposalStoreError.notFound(edited.id) }
            self.nudge(edited.id)
            return row.model
        }
    }

    public func join(_ id: UUID) async throws -> Proposal {
        try await perform { _ in
            try await self.client.rpc("join_proposal", params: ["p_id": id]).execute()
            let p = try await self.fetchProposal(id)
            self.nudge(id)
            return p
        }
    }

    public func lock(_ id: UUID, window: DateRange) async throws -> Proposal {
        try await perform { _ in
            try await self.client.rpc("lock_proposal", params: LockParams(p_id: id, p_start: window.lowerBound, p_end: window.upperBound)).execute()
            let p = try await self.fetchProposal(id)
            self.nudge(id)
            return p
        }
    }

    // MARK: Availability

    public func tapFree(proposalID: UUID, range: DateRange, expiresAt: Date?) async throws -> AvailabilitySlot {
        try await perform { me in
            // The server has no rule for a hold's plan, status or window (rls.sql lets a user write their
            // own rows), so these are the in-memory store's checks, made here against fresh data.
            let p = try await self.fetchProposal(proposalID)
            guard p.isRecipient(me) else {
                throw ProposalStoreError.server(code: "42501", message: "not a recipient of this proposal", hint: "FC_NOT_MEMBER")
            }
            guard p.status == .requesting else {
                throw ProposalStoreError.server(code: "55000", message: "proposal is \(p.status.rawValue), not requesting", hint: "FC_LOCKED")
            }
            guard p.window.lowerBound <= range.lowerBound, range.upperBound <= p.window.upperBound, range.lowerBound < range.upperBound else {
                throw ProposalStoreError.server(code: "22023", message: "hold must sit inside the proposal window", hint: "FC_WINDOW")
            }
            let own = try await self.ownSlots(of: me)
            switch self.availability.tapFreeSlot(userID: me, range: range, proposalID: proposalID, expiresAt: expiresAt, existingSlots: own, now: Date()) {
            case .alreadyHeld:
                throw ProposalStoreError.heldElsewhere
            case .softHold(let slot):
                try await self.client.from("availability_slots").insert(SlotInsert(slot)).execute()
                self.nudge(proposalID)
                return slot
            }
        }
    }

    public func release(slotID: UUID) async throws {
        try await perform { me in
            let rows: [IDRow] = try await self.client.from("availability_slots").delete()
                .eq("id", value: slotID.uuidString).eq("user_id", value: me.uuidString)
                .select("id,source_proposal_id").execute().value
            guard let row = rows.first else { throw ProposalStoreError.notFound(slotID) }
            if let pid = row.sourceProposalID { self.nudge(pid) }
        }
    }

    /// The caller's own holds and Busy blocks, for the clash check in `tapFreeSlot`.
    private func ownSlots(of me: UUID) async throws -> [AvailabilitySlot] {
        async let held: [SlotRow] = client.from("availability_slots").select(Self.slotColumns)
            .eq("user_id", value: me.uuidString).execute().value
        async let busy: [BusyRow] = client.from("busy_blocks").select("id,user_id,range,created_at")
            .eq("user_id", value: me.uuidString).execute().value
        return try await held.map(\.model) + busy.map(\.slot)
    }

    // MARK: Places

    public func suggestPlace(proposalID: UUID, _ place: NewPlace) async throws -> Place {
        try await perform { _ in
            let row: PlaceRow = try await self.client.rpc("suggest_place", params: SuggestParams(
                p_proposal_id: proposalID, p_name: place.name, p_address: place.address,
                p_lat: place.latitude, p_lon: place.longitude, p_map_ref: place.mapRef)).execute().value
            self.nudge(proposalID)
            return row.model
        }
    }

    public func votePlace(proposalID: UUID, placeID: UUID?) async throws {
        try await perform { _ in
            try await self.client.rpc("vote_place", params: VoteParams(p_proposal_id: proposalID, p_place_id: placeID)).execute()
            self.nudge(proposalID)
        }
    }

    public func vetoPlace(placeID: UUID, vetoed: Bool) async throws -> Place {
        try await perform { _ in
            let row: PlaceRow = try await self.client.rpc("veto_place", params: VetoParams(p_place_id: placeID, p_vetoed: vetoed)).execute().value
            self.nudge(row.proposalID)
            return row.model
        }
    }

    public func removePlace(placeID: UUID) async throws {
        try await perform { _ in
            // The RPC returns nothing, so learn the plan first: its watchers need the refresh.
            let rows: [PlaceRow] = try await self.client.from("proposal_places").select().eq("id", value: placeID.uuidString).limit(1).execute().value
            try await self.client.rpc("remove_place", params: ["p_place_id": placeID]).execute()
            if let pid = rows.first?.proposalID { self.nudge(pid) }
        }
    }

    // MARK: Changes (polling)

    public func changes(for id: UUID) -> AsyncStream<ProposalChange> {
        let token = UUID()
        return AsyncStream { continuation in
            let watcher = Watcher(continuation)
            watchers[id, default: [:]][token] = watcher
            // First snapshot straight away: a screen that opens on stale data should not wait a tick.
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.refresh(id)
                    guard let interval = self?.pollInterval else { return }
                    try? await Task.sleep(for: interval)
                }
            }
            continuation.onTermination = { [weak self] _ in
                poll.cancel()
                Task { @MainActor in self?.watchers[id]?.removeValue(forKey: token) }
            }
        }
    }

    /// Re-reads a plan once and hands it to every watcher whose last snapshot differs.
    private func refresh(_ id: UUID) async {
        guard let targets = watchers[id]?.values, !targets.isEmpty, currentUserID != nil else { return }
        let generation = identityGeneration
        do {
            let snap = try await fetchSnapshot(id)
            guard generation == identityGeneration, let live = watchers[id]?.values else { return }
            for w in live where w.last != snap {
                w.last = snap
                w.continuation.yield(.snapshot(snap))
            }
        } catch is CancellationError {
        } catch {
            // A failed poll is silent: the next one tries again, and a visible error here would fire
            // every few seconds on a train. A plan that is gone ends the stream, like the in-memory store.
            if case ProposalStoreError.notFound = Self.map(error) {
                for w in watchers[id]?.values ?? [:].values { w.continuation.finish() }
            }
        }
    }

    private func nudge(_ id: UUID) {
        guard watchers[id]?.isEmpty == false else { return }
        Task { @MainActor [weak self] in await self?.refresh(id) }
    }

    private func stopWatching() {
        for (_, group) in watchers { for w in group.values { w.continuation.finish() } }
        watchers = [:]
    }

    // MARK: Plumbing

    /// Capture the identity, run, re-check the identity, and map every failure into the store's own
    /// error type. Identical in purpose to the in-memory store's `authorize`: work begun as A must not
    /// land as B.
    private func perform<T>(_ body: (UUID) async throws -> T, finish: ((T) async -> Void)? = nil) async throws -> T {
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
        let generation = identityGeneration
        let result: T
        do {
            result = try await body(me)
        } catch {
            if generation != identityGeneration || currentUserID != me { throw ProposalStoreError.identityChanged }
            throw Self.map(error)
        }
        guard identityGeneration == generation, currentUserID == me else { throw ProposalStoreError.identityChanged }
        await finish?(result)
        return result
    }

    /// PostgREST's refusal, as the store's. The SQLSTATE and the `FC_*` hint are the contract; the
    /// message is for the Details line only and is never parsed.
    nonisolated static func map(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is ProposalStoreError, is UserFacingError:
            return error
        case let e as PostgrestError:
            return ProposalStoreError.server(code: e.code ?? "", message: e.message, hint: e.hint)
        case let e as AuthError:
            if case .sessionMissing = e { return ProposalStoreError.notSignedIn }
            return ProposalStoreError.network(e.localizedDescription)
        case let e as URLError:
            return ProposalStoreError.network(e.localizedDescription)
        default:
            return ProposalStoreError.network(error.localizedDescription)
        }
    }

    private static func badCity() -> ProposalStoreError {
        .server(code: "23514", message: "the city is not valid", hint: nil)
    }

    private static let proposalColumns = "id,title,window_start,window_end,created_by,distribution,status,locked_date,locked_end,created_at,area_name,area_lat,area_lon,locked_place_id,locked_attendee_ids,locked_at"
    private static let slotColumns = "id,user_id,range,source_proposal_id,state,expires_at,created_at"
}

// MARK: - Wire types

private struct DistributionJSON: Codable {
    var mode: String?
    var recipientIDs: [UUID]?
    var expectedCount: Int?
}

private struct ProposalRow: Decodable {
    var id: UUID
    var title: String
    var windowStart: Date
    var windowEnd: Date
    var createdBy: UUID?
    var distribution: DistributionJSON?
    var status: String
    var lockedDate: Date?
    var lockedEnd: Date?
    var createdAt: Date?
    var areaName: String?
    var areaLat: Double?
    var areaLon: Double?
    var lockedPlaceID: UUID?
    var lockedAttendeeIDs: [UUID]?
    var lockedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, distribution, status
        case windowStart = "window_start", windowEnd = "window_end", createdBy = "created_by"
        case lockedDate = "locked_date", lockedEnd = "locked_end", createdAt = "created_at"
        case areaName = "area_name", areaLat = "area_lat", areaLon = "area_lon"
        case lockedPlaceID = "locked_place_id", lockedAttendeeIDs = "locked_attendee_ids", lockedAt = "locked_at"
    }

    var model: Proposal {
        let dist = distribution
        let area: SearchArea? = {
            guard let n = areaName, let la = areaLat, let lo = areaLon else { return nil }
            return SearchArea(name: n, latitude: la, longitude: lo)
        }()
        return Proposal(
            id: id, title: title, window: DateRange(lower: windowStart, upper: windowEnd),
            // A deleted creator is nulled by the server; the id is only used for identity checks.
            createdBy: createdBy ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            distribution: Distribution(mode: dist?.mode.flatMap(DistributionMode.init(rawValue:)) ?? .newGroup,
                                       recipientIDs: dist?.recipientIDs ?? []),
            status: ProposalStatus(rawValue: status) ?? .requesting,
            createdAt: createdAt ?? Date(), lockedDate: lockedDate, lockedEnd: lockedEnd, area: area,
            lockedPlaceID: lockedPlaceID, expectedCount: dist?.expectedCount ?? 1,
            lockedAttendeeIDs: lockedAttendeeIDs ?? [], postLockRecipientIDs: [], lockedAt: lockedAt)
    }
}

private struct ProposalInsert: Encodable {
    var id: UUID
    var title: String
    var windowStart: Date
    var windowEnd: Date
    var createdBy: UUID
    var status: String
    var distribution: DistributionJSON
    var areaName: String?
    var areaLat: Double?
    var areaLon: Double?
    enum CodingKeys: String, CodingKey {
        case id, title, status, distribution
        case windowStart = "window_start", windowEnd = "window_end", createdBy = "created_by"
        case areaName = "area_name", areaLat = "area_lat", areaLon = "area_lon"
    }
}

private struct ProposalUpdate: Encodable {
    var title: String
    var areaName: String?
    var areaLat: Double?
    var areaLon: Double?
    enum CodingKeys: String, CodingKey {
        case title, areaName = "area_name", areaLat = "area_lat", areaLon = "area_lon"
    }
}

private struct UserRow: Decodable {
    var id: UUID
    var displayName: String
    var avatarURL: String?
    var deletedAt: Date?
    enum CodingKeys: String, CodingKey { case id, displayName = "display_name", avatarURL = "avatar_url", deletedAt = "deleted_at" }
    var model: User { User(id: id, displayName: displayName, avatarURL: avatarURL.flatMap(URL.init(string:))) }
}

private struct UserInsert: Encodable {
    var id: UUID
    var displayName: String
    enum CodingKeys: String, CodingKey { case id, displayName = "display_name" }
}

private struct SlotRow: Decodable {
    var id: UUID
    var userID: UUID
    var range: String
    var sourceProposalID: UUID?
    var state: String
    var expiresAt: Date?
    var createdAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, range, state
        case userID = "user_id", sourceProposalID = "source_proposal_id", expiresAt = "expires_at", createdAt = "created_at"
    }
    var model: AvailabilitySlot {
        let r = RangeText.parse(range) ?? DateRange(lower: Date(timeIntervalSince1970: 0), upper: Date(timeIntervalSince1970: 0))
        return AvailabilitySlot(id: id, userID: userID, range: r, sourceProposalID: sourceProposalID,
                                state: AvailabilityState(rawValue: state) ?? .softHold, createdAt: createdAt ?? Date(), expiresAt: expiresAt)
    }
}

private struct SlotInsert: Encodable {
    var id: UUID
    var userID: UUID
    var range: String
    var sourceProposalID: UUID?
    var state: String
    var expiresAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, range, state
        case userID = "user_id", sourceProposalID = "source_proposal_id", expiresAt = "expires_at"
    }
    init(_ slot: AvailabilitySlot) {
        id = slot.id; userID = slot.userID; range = RangeText.format(slot.range)
        sourceProposalID = slot.sourceProposalID; state = slot.state.rawValue; expiresAt = slot.expiresAt
    }
}

private struct IDRow: Decodable {
    var id: UUID
    var sourceProposalID: UUID?
    enum CodingKeys: String, CodingKey { case id, sourceProposalID = "source_proposal_id" }
}

private struct BusyRow: Decodable {
    var id: UUID
    var userID: UUID
    var range: String
    var createdAt: Date?
    enum CodingKeys: String, CodingKey { case id, range, userID = "user_id", createdAt = "created_at" }
    var slot: AvailabilitySlot {
        let r = RangeText.parse(range) ?? DateRange(lower: Date(timeIntervalSince1970: 0), upper: Date(timeIntervalSince1970: 0))
        return AvailabilitySlot(id: id, userID: userID, range: r, sourceProposalID: nil, state: .busy, createdAt: createdAt ?? Date())
    }
}

private struct PlaceRow: Decodable {
    var id: UUID
    var proposalID: UUID
    var suggestedBy: UUID
    var name: String
    var address: String?
    var lat: Double
    var lon: Double
    var mapRef: String?
    var vetoedAt: Date?
    var createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, name, address, lat, lon
        case proposalID = "proposal_id", suggestedBy = "suggested_by", mapRef = "map_ref", vetoedAt = "vetoed_at", createdAt = "created_at"
    }
    var model: Place {
        Place(id: id, proposalID: proposalID, suggestedBy: suggestedBy, name: name, address: address,
              latitude: lat, longitude: lon, mapRef: mapRef, vetoedAt: vetoedAt, createdAt: createdAt)
    }
}

private struct VoteRow: Decodable {
    var proposalID: UUID
    var voterID: UUID
    var placeID: UUID
    var createdAt: Date
    enum CodingKeys: String, CodingKey { case proposalID = "proposal_id", voterID = "voter_id", placeID = "place_id", createdAt = "created_at" }
    var model: PlaceVote { PlaceVote(proposalID: proposalID, voterID: voterID, placeID: placeID, createdAt: createdAt) }
}

private struct CommitmentRow: Decodable {
    var id: UUID
    var kind: String
    var rangeStart: Date
    var rangeEnd: Date
    var sourceProposalID: UUID?
    var planTitle: String?
    var expiresAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, kind
        case rangeStart = "range_start", rangeEnd = "range_end", sourceProposalID = "source_proposal_id"
        case planTitle = "plan_title", expiresAt = "expires_at"
    }
    var model: Commitment? {
        guard let k = CommitmentKind(rawValue: kind) else { return nil }
        return Commitment(id: id, kind: k, range: DateRange(lower: rangeStart, upper: rangeEnd),
                          sourceProposalID: sourceProposalID, planTitle: planTitle, expiresAt: expiresAt)
    }
}

private struct DeletionRow: Decodable {
    var alreadyDeleted: Bool
    var cancelledPlans: Int
    var releasedHolds: Int
    var lockedPlansKept: Int
    enum CodingKeys: String, CodingKey {
        case alreadyDeleted = "already_deleted", cancelledPlans = "cancelled_plans"
        case releasedHolds = "released_holds", lockedPlansKept = "locked_plans_kept"
    }
}

// RPC parameter names are the SQL parameter names, so these keep the `p_` prefix.
private struct FromParam: Encodable { var p_from: Date }
private struct LockParams: Encodable { var p_id: UUID; var p_start: Date; var p_end: Date }
private struct VetoParams: Encodable { var p_place_id: UUID; var p_vetoed: Bool }

/// Nulls are sent explicitly: Postgres resolves a function by its argument NAMES, so a missing
/// `p_place_id` is a different (nonexistent) function, not a null.
private struct VoteParams: Encodable {
    var p_proposal_id: UUID
    var p_place_id: UUID?
    enum CodingKeys: String, CodingKey { case p_proposal_id, p_place_id }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_proposal_id, forKey: .p_proposal_id)
        try c.encode(p_place_id, forKey: .p_place_id)
    }
}

private struct SuggestParams: Encodable {
    var p_proposal_id: UUID
    var p_name: String
    var p_address: String?
    var p_lat: Double
    var p_lon: Double
    var p_map_ref: String?
    enum CodingKeys: String, CodingKey { case p_proposal_id, p_name, p_address, p_lat, p_lon, p_map_ref }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_proposal_id, forKey: .p_proposal_id)
        try c.encode(p_name, forKey: .p_name)
        try c.encode(p_address, forKey: .p_address)
        try c.encode(p_lat, forKey: .p_lat)
        try c.encode(p_lon, forKey: .p_lon)
        try c.encode(p_map_ref, forKey: .p_map_ref)
    }
}

/// Postgres `tstzrange` text, e.g. `["2026-11-14 18:00:00+00","2026-11-14 20:00:00+00")`.
enum RangeText {
    static func format(_ range: DateRange) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "[\(f.string(from: range.lowerBound)),\(f.string(from: range.upperBound)))"
    }

    static func parse(_ text: String) -> DateRange? {
        guard text.count > 2, let open = text.first, let close = text.last, "[(".contains(open), ")]".contains(close) else { return nil }
        let parts = text.dropFirst().dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let lo = date(String(parts[0])), let hi = date(String(parts[1])) else { return nil }
        return DateRange(lower: lo, upper: hi)
    }

    private static func date(_ raw: String) -> Date? {
        var s = raw.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        if let space = s.firstIndex(of: " ") { s.replaceSubrange(space...space, with: "T") }
        // `+00` and `-08` are valid in Postgres output and not in ISO 8601 as Foundation reads it.
        if let tail = s.suffix(3).first, tail == "+" || tail == "-", s.count > 3 { s += ":00" }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
