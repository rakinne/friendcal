import Foundation
import Observation
import FriendCalCore

/// A group member as Home shows them: initials face, online dot, active arc.
struct HomeMember: Identifiable, Equatable {
    let id: UUID
    let name: String
    var isOnline: Bool
    var isActive: Bool

    /// "Sam" -> "SA", "Ana Ruiz" -> "AR".
    var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(name.prefix(2)).uppercased()
    }
}

/// One open proposal's state over a `ProposalStore` (issue #5 D2; HomeModel widened). Home, the
/// Locked Invite, the availability and lock sheets and the debug sheet are views over it. Heatmap
/// numbers, chips, the caption and Share all derive from HeatmapBuilder (X2) and `LockState` (S3);
/// selection follows the visible week (X6, X10). One session per open proposal (C9); the Invites
/// list has its own small `ProposalListModel`.
///
///     Creator phone                     store                        Recipient phone
///     CreateProposalSheet ──create────▶ proposals ◀────join──────── onOpenURL friendcal://proposal/<id>
///     ShareLink(friendcal://…) ── iMessage ───────────────────────▶ LockedInviteView "Locked until N more…"
///     changes(for:) ◀─snapshot──────── availability_slots ◀──tapFree── AvailabilitySheet tap
///       └─ HeatmapBuilder.weeks        proposals (recipients, status)   └─ rebuild, caption recounts
///     LockSheet ── lock(window) ─────▶ lock (server-first, R3) ──snapshot──▶ card settles: date + window, "You're in"
///           ▲ refusal mapped by UserFacingError, status stays requesting
/// Main-actor isolated: SwiftUI reads these observed properties on the main thread, and the async
/// methods below (lock, toggle, join, edit, load) write them. Without isolation a `Task` started
/// from a view hops to the global executor on the first `await session.x()` and mutates `weeks`,
/// `lockState` and `slots` mid-render (crash: bad release in `outlined destroy of HeatmapCell`).
@MainActor
@Observable
final class ProposalSession {
    enum Screen: Equatable {
        case loading
        case ready
        case error(UserFacingError)
        case gone
    }

    let groupName: String
    let calendar: Calendar
    let store: ProposalStore
    /// The clock every recount reads (C2); pinned by fixtures and tests.
    var now: () -> Date
    var isLoading: Bool
    var members: [HomeMember]
    var proposal: Proposal?
    var slots: [AvailabilitySlot]
    /// Place voting (#10): the plan's places and votes, and the board derived from them. Server-first:
    /// they change only when the store's snapshot is applied, never optimistically.
    private(set) var places: [Place] = []
    private(set) var votes: [PlaceVote] = []
    /// nil until a proposal is loaded.
    private(set) var board: PlaceBoard?
    var lastUpdated: Date
    private(set) var proposalID: UUID?
    private(set) var screen: Screen = .ready

    private(set) var weeks: [HeatmapWeek] = []
    private(set) var visibleWeekID: Date?
    private(set) var selectedCellID: HeatmapCell.ID?
    /// The availability sheet's chips follow the last-toggled cell (design 1.5A), independent of
    /// Home's selection.
    private(set) var markFocusCellID: HeatmapCell.ID?
    private(set) var lockState: LockState?
    /// One-shot (design 3.4A, delta A3): true after a snapshot moves the plan requesting -> locked;
    /// `consumeLockAcknowledgment()` clears it. A reload of an already-locked plan never sets it.
    private(set) var didJustLock = false

    private var needsLoad = false

    /// Home over a fixture (regression contract D10): seeds an in-memory store and the state in one
    /// step, so the three HomeModelTests run unchanged under the new name.
    convenience init(fixture: HomeFixture, now: Date = .now, calendar: Calendar = .current) {
        self.init(store: FixtureData.store(fixture, clock: { now }), fixture: fixture, calendar: calendar, now: { now })
    }

    /// Home over a store the shell also hands to the Invites tab: state seeded from the fixture
    /// synchronously, later changes observed from the store.
    init(store: ProposalStore, fixture: HomeFixture, calendar: Calendar = .current, now: @escaping () -> Date) {
        self.store = store
        self.groupName = fixture.groupName
        self.members = fixture.members
        self.proposalID = fixture.proposal?.id
        self.calendar = calendar
        self.now = now
        isLoading = fixture.isLoading
        proposal = fixture.proposal
        slots = fixture.slots
        places = fixture.places
        votes = fixture.votes
        lastUpdated = fixture.lastUpdated
        needsLoad = false
        refresh(now: now())
    }

    /// A proposal opened by id (Invites row, deep link, Home over a store): `run()` loads it.
    init(store: ProposalStore, groupName: String = "", members: [HomeMember] = [], proposalID: UUID?, calendar: Calendar = .current, now: @escaping () -> Date = { .now }) {
        self.store = store
        self.groupName = groupName
        self.members = members
        self.proposalID = proposalID
        self.calendar = calendar
        self.now = now
        isLoading = false
        slots = []
        lastUpdated = now()
        needsLoad = proposalID != nil
        screen = proposalID != nil ? .loading : .ready
    }

    // MARK: Identity

    var currentUserID: UUID? { store.currentUserID }
    /// The "DEMO" pill (D7): true on the in-memory store.
    var isDemo: Bool { store is InMemoryProposalStore }
    var isCreator: Bool { proposal?.isCreator(currentUserID) ?? false }
    var isRecipient: Bool { proposal?.isRecipient(currentUserID) ?? false }
    var creatorName: String? { proposal.flatMap { p in members.first { $0.id == p.createdBy }?.name } }
    /// A departed friend is "A friend" (design: Departed friend), not the tombstone's "Deleted account".
    func name(of id: UUID) -> String {
        guard let name = members.first(where: { $0.id == id })?.name, name != User.deletedDisplayName else { return "A friend" }
        return name
    }

    // MARK: Lifecycle

    /// Loads the proposal when it was opened by id (or re-fetches one already on screen, since a
    /// view's task restarts after a pushed screen covered it and snapshots emitted meanwhile were
    /// missed), then applies every store snapshot until the task is cancelled (D11). Views run it
    /// with `.task(id: session.proposalID)`.
    func run() async {
        guard let id = proposalID else {
            if needsLoad { await load() }
            return
        }
        // Subscribe before fetching: a snapshot emitted during the fetch is buffered, not lost.
        let changes = store.changes(for: id)
        if needsLoad { await load() } else { await reload() }
        for await change in changes {
            guard !Task.isCancelled else { return }
            if case .snapshot(let snapshot) = change { apply(snapshot) }
        }
        // The store finished the stream: the plan was removed.
        if !Task.isCancelled, proposalID == id { screen = .gone }
    }

    /// Fetches the snapshot. The first load shows the skeleton; a missing plan reads "gone" (design 2.2A).
    func load() async {
        guard let id = proposalID else { screen = .ready; return }
        if proposal == nil { screen = .loading }
        do {
            apply(try await store.load(id))
            needsLoad = false
            screen = .ready
        } catch ProposalStoreError.notFound {
            screen = .gone
        } catch {
            screen = .error(UserFacingError.map(error, action: .load, creatorName: creatorName))
        }
    }

    /// Re-fetches on return to foreground (failure-modes table): a failure keeps what is on screen.
    func reload() async {
        guard let id = proposalID else { return }
        if let snapshot = try? await store.load(id) { apply(snapshot); screen = .ready }
    }

    /// Switches this session to a proposal that was just created or joined (Home adopts the new plan).
    func adopt(_ id: UUID) {
        proposalID = id
        needsLoad = true
        proposal = nil
        slots = []
        places = []
        votes = []
        board = nil
        screen = .loading
    }

    /// Replaces the snapshot and recounts; fires the one-shot lock acknowledgment on requesting -> locked.
    /// `lastUpdated` moves only when the rows changed (X12: it tracks data, not fetches), so a
    /// foreground re-fetch of unchanged data keeps "Updated Nm ago".
    func apply(_ snapshot: ProposalSnapshot) {
        let wasRequesting = proposal?.status == .requesting
        let changed = snapshot.proposal != proposal || snapshot.slots != slots
            || snapshot.places != places || snapshot.votes != votes
        proposal = snapshot.proposal
        slots = snapshot.slots
        places = snapshot.places
        votes = snapshot.votes
        members = snapshot.members.map { user in
            let known = members.first { $0.id == user.id }
            return HomeMember(id: user.id, name: user.displayName, isOnline: known?.isOnline ?? false, isActive: known?.isActive ?? false)
        }
        if changed { lastUpdated = now() }
        isLoading = false
        refresh(now: now())
        if wasRequesting, snapshot.proposal.status == .locked { didJustLock = true }
    }

    func consumeLockAcknowledgment() -> Bool {
        defer { didJustLock = false }
        return didJustLock
    }

    // MARK: Recount

    /// Recounts with a fresh `now`, so holds that expired while the screen stayed open drop out of the
    /// counts, roster, best badge and share text with no new data (X12). Keeps the visible week
    /// when it still exists and re-resolves the selection (X6, X10). Views call `tick()` every
    /// minute and when the scene becomes active. `lastUpdated` is untouched: it tracks data
    /// changes, not recounts.
    func refresh(now: Date) {
        guard let p = proposal else {
            weeks = []; visibleWeekID = nil; selectedCellID = nil; markFocusCellID = nil; lockState = nil; board = nil
            return
        }
        board = PlaceBoard.make(places: places, votes: votes, viewer: currentUserID)
        weeks = HeatmapBuilder.weeks(slots: slots, window: p.window, recipientIDs: p.distribution.recipientIDs, expectedCount: p.expectedCount,
                                     proposalID: p.id, now: now, calendar: calendar)
        if !weeks.contains(where: { $0.id == visibleWeekID }) { visibleWeekID = weeks.first?.id }
        selectedCellID = HeatmapSelection.resolve(current: selectedCellID, week: visibleWeek)
        if !(visibleWeek?.cells.contains { $0.id == markFocusCellID && $0.isEnabled } ?? false) { markFocusCellID = visibleWeek?.best?.id }
        lockState = LockState.make(proposal: p, weeks: weeks)
    }

    func tick() { refresh(now: now()) }

    func showWeek(_ id: Date?) {
        guard let id, id != visibleWeekID, weeks.contains(where: { $0.id == id }) else { return }
        visibleWeekID = id
        selectedCellID = HeatmapSelection.resolve(current: selectedCellID, week: visibleWeek)
        markFocusCellID = visibleWeek?.best?.id
    }

    /// Only enabled cells of the visible week are selectable (D22).
    func select(_ id: HeatmapCell.ID) {
        guard visibleWeek?.cells.contains(where: { $0.id == id && $0.isEnabled }) == true else { return }
        selectedCellID = id
    }

    var visibleWeek: HeatmapWeek? { weeks.first { $0.id == visibleWeekID } }
    var selectedCell: HeatmapCell? { visibleWeek?.cells.first { $0.id == selectedCellID } }
    var markFocusCell: HeatmapCell? { visibleWeek?.cells.first { $0.id == markFocusCellID } }
    /// The quorum base, matching HeatmapBuilder's cell totals (D5, D13).
    var total: Int { proposal?.headcount ?? 0 }
    var onlineCount: Int { members.filter(\.isOnline).count }

    /// Home's Share: the selected slot while requesting (X9); the locked plan once locked (design 2.2A).
    var shareText: String? {
        guard let p = proposal else { return nil }
        if let window = p.lockedWindow, p.isLocked {
            return ShareText.locked(title: p.title, window: window, calendar: calendar, locale: .current, place: winner?.name)
        }
        guard let cell = selectedCell else { return nil }
        return ShareText.format(title: p.title, cell: cell, calendar: calendar, locale: .current)
    }

    /// The invite message with the deep link (design 3.5A).
    var inviteText: String? {
        proposal.map { ShareText.invite(title: $0.title, url: DeepLink.proposal($0.id, title: $0.title).url) }
    }

    /// VoiceOver hint when Share is disabled (X6, X10).
    var shareDisabledHint: String? {
        if selectedCell == nil { return "Pick a time first" }
        return HeatmapSelection.canShare(selectedCell) ? nil : "Nobody shares an hour here yet"
    }

    /// Wheel faces (D36): up to 10 members; past 10, 9 faces (the active friend always among them)
    /// and a "+N" face for the rest.
    var wheel: (faces: [HomeMember], overflow: Int) {
        guard members.count > 10 else { return (members, 0) }
        var faces = Array(members.prefix(9))
        if let active = members.first(where: \.isActive), !faces.contains(active) { faces[8] = active }
        return (faces, members.count - 9)
    }

    /// The selected cell's statuses, in member order; nil hides the chips (D19) and strips status
    /// from the drawer (X11).
    var chips: [(member: HomeMember, status: CellStatus)]? {
        guard let roster = selectedCell?.roster, !roster.isEmpty else { return nil }
        return members.compactMap { m in roster[m.id].map { (m, $0) } }
    }

    /// The availability sheet's chips: the last-toggled cell's roster (design 1.5A).
    var markChips: [(member: HomeMember, status: CellStatus)]? {
        guard let roster = markFocusCell?.roster, !roster.isEmpty else { return nil }
        return members.compactMap { m in roster[m.id].map { (m, $0) } }
    }

    /// Once locked, Home's chips read "in" for attendees (design 2.2A), from the proposal row (X1).
    var attendeeChips: [(member: HomeMember, isIn: Bool)]? {
        guard let p = proposal, p.isLocked else { return nil }
        return members.map { ($0, p.lockedAttendeeIDs.contains($0.id)) }
    }

    /// The cell holding the locked window's start (design 2.2A "locked cell pill").
    var lockedCellID: HeatmapCell.ID? {
        guard let p = proposal, p.isLocked, let start = p.lockedDate else { return nil }
        return weeks.lazy.flatMap(\.cells).first { $0.interval.map { $0.lowerBound <= start && start < $0.upperBound } ?? false }?.id
    }

    // MARK: Marking availability (D9, C3)

    /// Cells the current user holds: an unexpired softHold of theirs on this plan covers the cell's
    /// whole interval. Drives the ring + check in the availability sheet (design 5.1A).
    var myHoldCellIDs: Set<HeatmapCell.ID> {
        guard let me = currentUserID, let p = proposal else { return [] }
        let mine = slots.filter { $0.userID == me && $0.sourceProposalID == p.id && $0.state == .softHold && !$0.isExpired(at: now()) }
        guard !mine.isEmpty else { return [] }
        var out = Set<HeatmapCell.ID>()
        for cell in weeks.lazy.flatMap(\.cells) {
            guard let interval = cell.interval else { continue }
            if mine.contains(where: { $0.range.lowerBound <= interval.lowerBound && interval.upperBound <= $0.range.upperBound }) { out.insert(cell.id) }
        }
        return out
    }

    /// A past cell (design 5.2A, D9): its interval ended before now.
    func isPast(_ cell: HeatmapCell) -> Bool {
        guard let interval = cell.interval else { return false }
        return interval.upperBound <= now()
    }

    /// "Sat morning, Sat afternoon, +2 more" (design 3.1A): up to three of my marked slots in order.
    var freeSummary: String? {
        let mine = myHoldCellIDs
        guard !mine.isEmpty else { return nil }
        let cells = weeks.lazy.flatMap(\.cells).filter { mine.contains($0.id) }
        let names = cells.prefix(3).map { DateText.dayPart(day: $0.day, daypart: $0.daypart, calendar: self.calendar, locale: .current) }
        let more = cells.count - names.count
        return names.joined(separator: ", ") + (more > 0 ? ", +\(more) more" : "")
    }

    /// Cells whose hold write (mark or release) is still in flight. A second tap on one is ignored
    /// until the first settles: it would otherwise read the optimistic row as a saved hold, release
    /// an id the store never issued and revert a write that then lands anyway.
    @ObservationIgnored private var pendingCellIDs: Set<HeatmapCell.ID> = []

    /// Toggles the current user's hold for `cell` (C3, D9): tap writes a softHold for the cell's
    /// interval expiring at its end; a second tap releases it. Optimistic, reverted on failure by
    /// slot id, so an overlapping toggle on another cell is never rolled back with it.
    /// Returns the mapped error for the sheet's toast, nil on success (and nil for an ignored tap).
    @discardableResult
    func toggle(_ cell: HeatmapCell) async -> UserFacingError? {
        guard let p = proposal, p.status == .requesting, let interval = cell.interval, !isPast(cell), let me = currentUserID,
              !pendingCellIDs.contains(cell.id) else { return nil }
        pendingCellIDs.insert(cell.id)
        defer { pendingCellIDs.remove(cell.id) }
        markFocusCellID = cell.id
        if myHoldCellIDs.contains(cell.id) {
            let mine = slots.filter { $0.userID == me && $0.sourceProposalID == p.id && $0.state == .softHold && $0.range.intersects(interval) }
            slots.removeAll { s in mine.contains { $0.id == s.id } }
            refresh(now: now())
            var released = Set<UUID>()
            do {
                for slot in mine {
                    try await store.release(slotID: slot.id)
                    released.insert(slot.id)
                }
                return nil
            } catch {
                // Put back only the holds the store still has: those it already dropped stay gone.
                slots.append(contentsOf: mine.filter { !released.contains($0.id) })
                refresh(now: now())
                return UserFacingError.map(error, action: .mark, creatorName: creatorName)
            }
        } else {
            let optimistic = AvailabilitySlot(userID: me, range: interval, sourceProposalID: p.id, state: .softHold, createdAt: now(), expiresAt: interval.upperBound)
            slots.append(optimistic)
            refresh(now: now())
            do {
                let written = try await store.tapFree(proposalID: p.id, range: interval, expiresAt: interval.upperBound)
                if let i = slots.firstIndex(where: { $0.id == optimistic.id }) { slots[i] = written }
                refresh(now: now())
                return nil
            } catch {
                slots.removeAll { $0.id == optimistic.id }
                refresh(now: now())
                return UserFacingError.map(error, action: .mark, creatorName: creatorName)
            }
        }
    }

    // MARK: Lock (C5, D14)

    /// The common span the lock sheet offers durations over (design 5.3A, D22).
    var lockSpan: DateRange? { lockState?.bestCell?.commonWindow }

    /// Validates, asks the store (server-first, R3) and applies the returned proposal. Throws a
    /// `UserFacingError`; the status stays requesting on refusal.
    func lock(duration: TimeInterval?) async throws {
        guard let p = proposal, let cell = lockState?.bestCell else { throw UserFacingError(message: "Nobody shares an hour yet.") }
        do {
            let window = try ProposalService().validateLock(cell: cell, duration: duration)
            let locked = try await store.lock(p.id, window: window)
            // Carry the places and votes this session holds: a snapshot built without them would blank
            // the board, and `winner` could not resolve `lockedPlaceID` until a later stream delivery.
            apply(ProposalSnapshot(proposal: locked, members: members.map { User(id: $0.id, displayName: $0.name) },
                                   slots: slots.filter { $0.sourceProposalID != p.id }, places: places, votes: votes))
        } catch {
            throw UserFacingError.map(error, action: .lock, creatorName: creatorName)
        }
    }

    // MARK: Places (#10)

    var hasArea: Bool { proposal?.area != nil }

    /// Why Suggest is, or is not, offered (design 7.5A): the screen picks its muted line, or its no-city
    /// row, from this one value.
    var suggestAvailability: SuggestAvailability {
        PlaceBoard.suggestAvailability(proposal: proposal, places: places, viewer: currentUserID)
    }
    var canSuggest: Bool { suggestAvailability == .available }

    /// The place frozen at lock: the row `proposal.lockedPlaceID` names, on a locked plan only. Never
    /// recomputed from votes, so it is nil when the plan locked with no winner even if `board.leaderID` is not.
    var winner: Place? {
        guard let p = proposal, p.isLocked, let id = p.lockedPlaceID else { return nil }
        return places.first { $0.id == id }
    }

    /// What locking now would freeze, for the lock sheet.
    var lockProjection: LockProjection { PlaceBoard.projection(places: places, votes: votes) }

    /// The stored row, which may be an existing duplicate.
    @discardableResult
    func suggest(_ place: NewPlace) async throws -> Place {
        let id = try placePlanID()
        do {
            let saved = try await store.suggestPlace(proposalID: id, place)
            await adoptStoreState()
            return saved
        } catch {
            await reconcile(after: error)
            throw UserFacingError.map(error, action: .suggestPlace, creatorName: creatorName)
        }
    }

    /// nil clears the caller's vote.
    func vote(_ placeID: UUID?) async throws {
        let id = try placePlanID()
        do {
            try await store.votePlace(proposalID: id, placeID: placeID)
            await adoptStoreState()
        } catch {
            await reconcile(after: error)
            throw UserFacingError.map(error, action: .votePlace, creatorName: creatorName)
        }
    }

    /// Host only. `vetoed: false` is "Bring back".
    func setVeto(_ placeID: UUID, vetoed: Bool) async throws {
        _ = try placePlanID()
        do {
            _ = try await store.vetoPlace(placeID: placeID, vetoed: vetoed)
            await adoptStoreState()
        } catch {
            let subject = places.first { $0.id == placeID }.map { name(of: $0.suggestedBy) }
            await reconcile(after: error)
            throw UserFacingError.map(error, action: vetoed ? .vetoPlace : .bringBack, creatorName: creatorName, subjectName: subject)
        }
    }

    /// The suggester withdraws their own place.
    func withdraw(_ placeID: UUID) async throws {
        _ = try placePlanID()
        do {
            try await store.removePlace(placeID: placeID)
            await adoptStoreState()
        } catch {
            await reconcile(after: error)
            throw UserFacingError.map(error, action: .removePlace, creatorName: creatorName)
        }
    }

    /// A refusal that means the screen is stale (design 2.8A: FC_VETOED, FC_LOCKED, FC_PLACE_NOT_FOUND,
    /// FC_NOT_FOUND, FC_NOT_MEMBER) is followed by taking the server's state, so the row flips to Passed,
    /// the plan reloads as locked, or the missing row disappears, rather than only showing a sentence.
    /// A network failure changes nothing on the server, so it keeps the screen as it is.
    private func reconcile(after error: Error) async {
        guard case let ProposalStoreError.server(_, _, hint) = error,
              let hint, ["FC_VETOED", "FC_LOCKED", "FC_PLACE_NOT_FOUND", "FC_NOT_FOUND", "FC_NOT_MEMBER", "FC_CLOSED"].contains(hint) else { return }
        await adoptStoreState()
    }

    private func placePlanID() throws -> UUID {
        guard let id = proposalID, proposal != nil else { throw UserFacingError(message: "This plan is gone.") }
        return id
    }

    /// Mutations are server-first: after one succeeds, take the store's state rather than waiting for
    /// the stream, so the result does not depend on delivery timing. The stream delivers the same
    /// snapshot later, which changes nothing.
    private func adoptStoreState() async {
        guard let id = proposalID, let snapshot = try? await store.load(id) else { return }
        apply(snapshot)
    }

    // MARK: Join / create / edit

    func join() async throws {
        guard let id = proposalID else { return }
        do {
            _ = try await store.join(id)
            await load()
        } catch {
            throw UserFacingError.map(error, action: .join, creatorName: creatorName)
        }
    }

    /// Creator edits (design 5.4A); the store enforces the rules and the session applies the result.
    func edit(_ draft: ProposalDraft) async throws {
        guard var p = proposal else { return }
        do {
            let plan = try draft.validate(calendar: calendar)
            p.title = plan.title
            // Dates the host did not touch keep the stored window exactly. The draft rebuilds the window by
            // day-snapping, and a stored window that was not already snapped would then read as a date
            // change, which the store refuses once friends have marked times. That would block the one
            // edit that stays open then: replacing the city (design 5.4A, PL-5). A real date change still
            // goes through, so the store keeps enforcing the freeze.
            if ProposalDraft(editing: p).window(calendar: calendar) != plan.window { p.window = plan.window }
            p.expectedCount = max(plan.expectedCount, p.joinedCount)
            // The city travels with the rest of the edit. Copying only title, window and headcount would
            // drop a city change while the dates are frozen.
            p.area = plan.area
            let saved = try await store.update(p)
            apply(ProposalSnapshot(proposal: saved, members: members.map { User(id: $0.id, displayName: $0.name) },
                                   slots: slots, places: places, votes: votes))
        } catch {
            throw UserFacingError.map(error, action: .edit, creatorName: creatorName)
        }
    }

    /// Any hold on the plan freezes the dates (design 5.4A).
    var hasAnyHold: Bool {
        guard let p = proposal else { return false }
        return slots.contains { $0.sourceProposalID == p.id && $0.state == .softHold && !$0.isExpired(at: now()) }
    }
}
