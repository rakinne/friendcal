import Foundation
import Observation
import FriendCalCore

/// Poke and Tag along, as one observable value shared by every screen.
///
///     Home "Poke" ─┐
///     Groups row ──┤                          ┌─> store.sendPoke ──> toast + haptic
///     Friend card ─┼──> SocialSession.poke ───┤
///     Moments ─────┤                          └─> inbox (the Pokes tab, every "58 min left")
///     Pokes tab ───┘
///
/// One instance lives in the shell and is handed to each tab, so there is exactly one place a poke
/// is sent from and one copy of the inbox. A screen never calls the store's poke operations itself:
/// that is what keeps "poke" meaning the same thing on Home as on Groups (same rule, same toast,
/// same in-flight guard, same permission ask), and what lets a poke sent on one tab show its
/// countdown on another without a refetch.
///
/// The rules themselves are not here. They are in the store (supabase/social.sql and its in-memory
/// mirror) and the wording is in `PokeText`; this class sequences them and holds the result.
@MainActor
@Observable
final class SocialSession {
    enum NotificationState: Equatable { case unknown, notDetermined, denied, authorized }

    let store: ProposalStore
    let toasts: ToastCenter
    let clock: () -> Date
    /// How often the inbox re-reads while the app is open. A push also triggers a read, so this only
    /// bounds how stale a "seen" can be when no push is involved.
    var pollInterval: Duration = .seconds(20)

    private(set) var inbox: SocialInbox = .empty
    private(set) var hasLoaded = false
    private(set) var loadError: UserFacingError?
    /// Friends with a poke in flight, so a double tap is one request.
    private(set) var sending: Set<UUID> = []
    /// Pokes with an acknowledgement in flight.
    private(set) var answering: Set<UUID> = []
    /// Haptic triggers: one bump per poke that actually went, and per plan joined.
    private(set) var pokesSent = 0
    private(set) var plansJoined = 0
    private(set) var notifications: NotificationState = .unknown

    init(store: ProposalStore, toasts: ToastCenter = ToastCenter(), now: @escaping () -> Date = { .now }) {
        self.store = store
        self.toasts = toasts
        self.clock = now
    }

    var me: UUID? { store.currentUserID }
    var now: Date { clock() }
    /// Demo data never asks for notification permission or registers a device: there is nobody to
    /// push to, and a system alert over a UI test is a hung test.
    var isDemo: Bool { store is InMemoryProposalStore }

    // MARK: Reading

    var feed: PokeFeed { PokeFeed.build(inbox, me: me, now: now) }
    /// Live pokes waiting for the viewer: the Pokes tab's badge.
    var badge: Int { feed.forYou.count }

    func name(of id: UUID) -> String { inbox.name(of: id) }
    func planTitle(of poke: Poke) -> String? { poke.proposalID.flatMap { inbox.planTitles[$0] } }

    /// The live poke the viewer has out to this friend, if any.
    func livePoke(to friend: UUID) -> Poke? { PokeFeed.livePoke(in: inbox, from: me, to: friend, now: now) }

    /// "52 min left" while a poke to this friend is out; nil otherwise. What a Poke button shows.
    func pokeCountdown(to friend: UUID) -> String? {
        guard let poke = livePoke(to: friend), case .live(let remaining) = poke.state(at: now) else { return nil }
        return PokeText.countdown(remaining)
    }

    // MARK: Loading

    /// Reads the inbox until cancelled. The shell runs it with `.task`.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// A failed read keeps what is on screen: only a first load with nothing to show reports it.
    func refresh() async {
        do {
            let fresh = try await store.inbox()
            if fresh != inbox { inbox = fresh }
            loadError = nil
            hasLoaded = true
        } catch is CancellationError {
        } catch ProposalStoreError.identityChanged, ProposalStoreError.notSignedIn {
        } catch {
            if !hasLoaded { loadError = UserFacingError.map(error, action: .load) }
        }
    }

    // MARK: Poke (the one path)

    /// Pokes a friend. Every Poke control in the app ends here.
    ///
    /// Returns whether a poke is out to them afterwards. The toast is `PokeText.sent`, so a repeat
    /// says how long the first has left instead of pretending to send another.
    @discardableResult
    func poke(_ friend: UUID, name: String, about proposalID: UUID? = nil) async -> Bool {
        guard !sending.contains(friend) else { return false }
        sending.insert(friend)
        defer { sending.remove(friend) }
        do {
            let receipt = try await store.sendPoke(to: friend, about: proposalID)
            adopt(receipt.poke, name: name)
            if receipt.isNew { pokesSent += 1 }
            toasts.show(PokeText.sent(name: name, receipt: receipt, now: now))
            // Ask once there is a reason to: they will want to know when this one is answered.
            if receipt.isNew { await askForNotificationsIfUndecided() }
            // Poking back answered theirs on the server; read it rather than guess.
            await refresh()
            return true
        } catch is CancellationError {
            return false
        } catch {
            toasts.show(UserFacingError.map(error, action: .poke).message, duration: ToastCenter.errorSeconds)
            return false
        }
    }

    /// Pokes several friends about one plan (Home's "Poke all"), one after another so each gets the
    /// same rule and the toast reports what actually went.
    func poke(all targets: [PokeTarget], about proposalID: UUID?) async {
        var sent = 0
        var failure: UserFacingError?
        for target in targets where livePoke(to: target.id) == nil {
            do {
                let receipt = try await store.sendPoke(to: target.id, about: proposalID)
                adopt(receipt.poke, name: target.name)
                if receipt.isNew { sent += 1 }
            } catch is CancellationError {
                return
            } catch {
                failure = UserFacingError.map(error, action: .poke)
            }
        }
        if sent > 0 {
            pokesSent += 1
            toasts.show(sent == 1 ? "Poked 1 friend. It fades in an hour." : "Poked \(sent) friends. They fade in an hour.")
            await askForNotificationsIfUndecided()
        } else if let failure {
            toasts.show(failure.message, duration: ToastCenter.errorSeconds)
        } else {
            toasts.show("Everyone here already has your poke.")
        }
        await refresh()
    }

    /// "Got it" in the app, or a tapped push. A poke that is already gone is not worth an error.
    func acknowledge(_ id: UUID, via: Poke.AckVia = .app) async {
        guard !answering.contains(id) else { return }
        answering.insert(id)
        defer { answering.remove(id) }
        do {
            let poke = try await store.acknowledgePoke(id, via: via)
            adopt(poke, name: nil)
            await refresh()
        } catch is CancellationError {
        } catch ProposalStoreError.server(_, _, "FC_POKE_NOT_FOUND"?) {
            await refresh()
        } catch {
            toasts.show(UserFacingError.map(error, action: .ackPoke).message, duration: ToastCenter.errorSeconds)
        }
    }

    private func adopt(_ poke: Poke, name: String?) {
        var next = inbox
        if let index = next.pokes.firstIndex(where: { $0.id == poke.id }) { next.pokes[index] = poke } else { next.pokes.append(poke) }
        if let name, let me, let other = [poke.fromID, poke.toID].first(where: { $0 != me }) { next.names[other] = name }
        inbox = next
    }

    // MARK: Tag along

    /// The friend's plans the viewer can join right now (the Tag along sheet).
    func plans(with friend: UUID) async throws -> [Proposal] {
        do {
            let all = try await store.proposals().map(\.proposal)
            return TagAlongRules.candidates(all, with: friend, me: me, now: now)
        } catch {
            throw UserFacingError.map(error, action: .load)
        }
    }

    /// Joins a locked plan. Returns the plan as the server left it, or throws the sentence to show.
    @discardableResult
    func tagAlong(_ proposalID: UUID, hostName: String?) async throws -> Proposal {
        do {
            let plan = try await store.tagAlong(proposalID)
            plansJoined += 1
            toasts.show(TagAlongRules.joinedText(planTitle: plan.title, hostName: hostName, isHost: plan.createdBy == me))
            return plan
        } catch {
            throw UserFacingError.map(error, action: .tagAlong, creatorName: hostName)
        }
    }

    // MARK: Push

    /// Reads the permission state and, when already allowed, makes sure this device is registered.
    func startNotifications() async {
        guard !isDemo else { notifications = .unknown; return }
        notifications = await PushCoordinator.state()
        if notifications == .authorized { PushCoordinator.register() }
        if let token = PushCoordinator.deviceToken { await registerDevice(token) }
    }

    /// The Pokes tab's "Turn on" button.
    func turnOnNotifications() async {
        guard !isDemo else { return }
        if notifications == .denied {
            PushCoordinator.openSettings()
        } else {
            notifications = await PushCoordinator.request() ? .authorized : await PushCoordinator.state()
        }
    }

    private func askForNotificationsIfUndecided() async {
        guard !isDemo else { return }
        if notifications == .unknown { notifications = await PushCoordinator.state() }
        guard notifications == .notDetermined else { return }
        notifications = await PushCoordinator.request() ? .authorized : await PushCoordinator.state()
    }

    /// APNs handed the app a token. A failure here is silent and retried on the next launch: the
    /// person did nothing that needs an answer.
    func registerDevice(_ token: String) async {
        guard !isDemo else { return }
        #if DEBUG
        let sandbox = true
        #else
        let sandbox = false
        #endif
        try? await store.registerDevice(token: token, sandbox: sandbox)
    }
}

extension SocialSession {
    /// Previews and screens built without a shell.
    static func preview(_ scenario: FixtureScenario = .populated) -> SocialSession {
        let fixture = FixtureData.make(scenario)
        return SocialSession(store: FixtureData.store(fixture, clock: FixtureClock.now), now: FixtureClock.now)
    }
}
