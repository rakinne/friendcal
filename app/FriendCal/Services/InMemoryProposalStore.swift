import Foundation

/// The in-app `ProposalStore` (issue #5 D2, D7): fixture-seeded, Simulator-testable, no credentials.
/// It is the real seam, not a stub: every rule lock_proposal.sql and join_proposal.sql enforce is
/// mirrored here with the same SQLSTATE and `FC_*` hint, so the session and the screens behave the
/// same on demo data as on the network store that PR2 adds. Absorbs the former DebugProposalModel
/// and MockSupabaseService (S1, S2). Main-thread use; `changes(for:)` continuations are locked.
public final class InMemoryProposalStore: ProposalStore {
    public enum Operation: Hashable, CaseIterable {
        case proposals, load, create, update, join, tapFree, release, lock
    }

    public private(set) var users: [User]
    public private(set) var proposals: [Proposal]
    public private(set) var slots: [AvailabilitySlot]
    public var busyBlocks: [BusyBlock]
    public private(set) var currentUserID: UUID?
    /// Injected clock (C2): expiry, createdAt and lockedAt read it.
    public var now: () -> Date
    /// Test hook (design 2.3A): the next call of a listed operation throws its error instead of
    /// running, so the error map and every revert path are exercised without a network.
    public var failNext: [Operation: Error] = [:]
    /// Artificial latency for every operation (loading states in UI tests).
    public var latency: Duration = .zero

    private let availability = AvailabilityService()
    private var continuations: [UUID: [UUID: AsyncStream<ProposalChange>.Continuation]] = [:]
    private let lock = NSLock()

    public init(users: [User] = [], proposals: [Proposal] = [], slots: [AvailabilitySlot] = [], busyBlocks: [BusyBlock] = [], currentUserID: UUID? = nil, now: @escaping () -> Date = { .now }) {
        self.users = users
        self.proposals = proposals
        self.slots = slots
        self.busyBlocks = busyBlocks
        self.currentUserID = currentUserID
        self.now = now
    }

    // MARK: ProposalStore

    public func signIn(displayName: String?) async throws -> UUID {
        if let id = currentUserID { return id }
        let user = User(id: UUID(), displayName: displayName ?? "You")
        users.append(user)
        currentUserID = user.id
        return user.id
    }

    public func proposals() async throws -> [ProposalSummary] {
        try await gate(.proposals)
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
        return proposals
            .filter { $0.createdBy == me || $0.isRecipient(me) }
            .map { ProposalSummary(proposal: $0, joinedCount: $0.joinedCount, isHosting: $0.createdBy == me) }
    }

    public func load(_ id: UUID) async throws -> ProposalSnapshot {
        try await gate(.load)
        return try snapshot(of: id)
    }

    public func create(_ plan: NewProposal) async throws -> Proposal {
        try await gate(.create)
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
        ensureUser(me)
        let proposal = Proposal(id: UUID(), title: plan.title, window: plan.window, createdBy: me,
                                distribution: Distribution(mode: .newGroup, recipientIDs: [me]),
                                status: .requesting, createdAt: now(), expectedCount: plan.expectedCount)
        proposals.append(proposal)
        return proposal
    }

    public func update(_ edited: Proposal) async throws -> Proposal {
        try await gate(.update)
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
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
        current.title = edited.title
        current.window = edited.window
        current.expectedCount = edited.expectedCount
        current.venueHint = edited.venueHint
        proposals[index] = current
        emit(current.id)
        return current
    }

    public func join(_ id: UUID) async throws -> Proposal {
        try await gate(.join)
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
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

    public func myCommitments() async throws -> [AvailabilitySlot] {
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
        return commitments(of: me)
    }

    public func tapFree(proposalID: UUID, range: DateRange, expiresAt: Date?) async throws -> AvailabilitySlot {
        try await gate(.tapFree)
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
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
        switch availability.tapFreeSlot(userID: me, range: range, proposalID: proposalID, expiresAt: expiresAt, existingSlots: commitments(of: me), now: now()) {
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
        try await gate(.release)
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
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
        try await gate(.lock)
        guard let me = currentUserID else { throw ProposalStoreError.notSignedIn }
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
        busyBlocks.filter { $0.range.overlaps(range) }.map { block in
            if block.hiddenFrom.contains(viewerID) {
                return BusyBlock(id: block.id, userID: block.userID, range: block.range, visibility: .public, hiddenFrom: [], createdAt: block.createdAt)
            }
            return block
        }
    }

    // MARK: Seeding

    /// Replaces the seeded rows (fixtures, previews).
    public func seed(users: [User], proposals: [Proposal], slots: [AvailabilitySlot], busyBlocks: [BusyBlock] = [], currentUserID: UUID?) {
        self.users = users
        self.proposals = proposals
        self.slots = slots
        self.busyBlocks = busyBlocks
        self.currentUserID = currentUserID
    }

    /// Removes a proposal and its rows ("This plan is gone" paths).
    public func remove(proposalID: UUID) {
        proposals.removeAll { $0.id == proposalID }
        slots.removeAll { $0.sourceProposalID == proposalID }
        emit(proposalID)
    }

    /// Synchronous read for seeding a session before any await.
    public func snapshot(of id: UUID) throws -> ProposalSnapshot {
        guard let p = proposals.first(where: { $0.id == id }) else { throw ProposalStoreError.notFound(id) }
        let members = p.joinedIDs.map { uid in users.first { $0.id == uid } ?? User(id: uid, displayName: "Friend") }
        return ProposalSnapshot(proposal: p, members: members, slots: slots.filter { $0.sourceProposalID == id })
    }

    // MARK: Private

    private func gate(_ op: Operation) async throws {
        if latency > .zero { try? await Task.sleep(for: latency) }
        if let error = failNext.removeValue(forKey: op) { throw error }
    }

    private func ensureUser(_ id: UUID) {
        if !users.contains(where: { $0.id == id }) { users.append(User(id: id, displayName: "You")) }
    }

    private func commitments(of user: UUID) -> [AvailabilitySlot] {
        slots.filter { $0.userID == user } + busyBlocks.filter { $0.userID == user }.map {
            AvailabilitySlot(id: $0.id, userID: $0.userID, range: $0.range, sourceProposalID: nil, state: .busy, createdAt: $0.createdAt)
        }
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
