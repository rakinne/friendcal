import SwiftUI
import FriendCalCore

/// The invite as a live proposal state (issue #5 D1, design 1.1A, 2.1A, 2.2A, 3.1A, 3.4A, 7.1B):
/// the card with the per-state caption, one coral control (Invite friends for the creator alone,
/// Lock for the creator at quorum), the teal availability link, the progress line and the "you're
/// free" line; the settled card with the attendance line once locked. Loading, error and gone states
/// per the interaction table. The lock acknowledgment fires once per requesting -> locked.
struct LockedInviteView: View {
    var session: ProposalSession
    /// "Go to Invites" from the gone state.
    var onGoToInvites: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAvailability = false
    @State private var showLock = false
    /// Edit plan. The item carries whether it opens on the city picker (the Places "Choose a city" pill):
    /// a separate flag set alongside `isPresented` was read stale when the sheet first presented.
    @State private var editSheet: EditSheet?

    private struct EditSheet: Identifiable {
        let id = UUID()
        var startsOnCityPicker = false
    }
    @State private var lockAck = 0
    @State private var joinError: UserFacingError?
    @State private var placesToast = ToastCenter()
    @State private var minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch session.screen {
                case .loading: loading
                case .error(let error): errorState(error)
                case .gone: gone
                case .ready: content
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: session.proposal?.status)
        }
        .scrollBounceBehavior(.basedOnSize)
        .toast(placesToast)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .navigationTitle(session.lockState?.navTitle ?? "Locked Invite")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if case .ready = session.screen, session.proposal != nil { ToolbarItem(placement: .topBarTrailing) { menu } } }
        .task(id: session.proposalID) { await session.run() }
        .onReceive(minuteTick) { _ in session.tick() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { session.tick(); Task { await session.reload() } } }
        .onChange(of: session.didJustLock) { _, fired in if fired, session.consumeLockAcknowledgment() { lockAck += 1 } }
        .onChange(of: session.screen) { _, screen in if screen == .ready { joinIfNeeded() } }
        .onAppear { if session.screen == .ready { joinIfNeeded() } }
        .sensoryFeedback(.success, trigger: lockAck)
        .sheet(isPresented: $showAvailability) {
            AvailabilitySheet(session: session)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLock) {
            LockSheet(session: session)
        }
        .sheet(item: $editSheet) { edit in
            CreateProposalSheet(mode: .edit(session), startOnCityPicker: edit.startsOnCityPicker, onCreated: { _ in })
                .presentationDetents([.large])
        }
    }

    // MARK: Ready

    @ViewBuilder
    private var content: some View {
        if let p = session.proposal, let state = session.lockState {
            let caption = state.caption(creatorName: session.creatorName, isCreator: session.isCreator)
            let window = p.lockedWindow
            InviteCard(title: p.displayTitle, caption: caption, isLocked: state.isLocked,
                       lockedDay: window.map { DateText.day($0.lowerBound, calendar: session.calendar, locale: .current) },
                       lockedTime: window.map { DateText.timeRange($0, calendar: session.calendar, locale: .current) },
                       accessibilityLabel: cardLabel(p, state, caption))

            // The place the lock froze, attached under the card (design PL-7). It fades in with the lock
            // crossfade (320ms) and is instant under Reduce Motion.
            if state.isLocked, let winner = session.winner {
                WinnerRow(place: winner).transition(.opacity)
            }

            if let error = joinError {
                InlineError(error: error, retryTitle: "Retry") { joinIfNeeded(force: true) }
            }

            if let primary = state.primaryTitle(isCreator: session.isCreator, calendar: session.calendar) {
                if case .inviteFriends = state, let text = session.inviteText {
                    ShareLink(item: text) { PrimaryPill(title: primary) }
                        .accessibilityIdentifier("invite.primary")
                } else {
                    Button { showLock = true } label: { PrimaryPill(title: primary) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("invite.primary")
                }
            }

            if let link = state.linkTitle(hasMyHolds: session.freeSummary != nil) {
                Button { showAvailability = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.open").imageScale(.small).accessibilityHidden(true)
                        Text(link).textStyle(.title)
                        Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
                    }
                    .foregroundStyle(DesignTokens.Colors.accentHover)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!session.isRecipient)
                .accessibilityHint("Mark your availability to unlock")
                .accessibilityIdentifier("invite.unlock")
            }

            if !state.isLocked, let free = session.freeSummary {
                Text("You're free \(free)")
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
                    .accessibilityIdentifier("invite.free")
            }

            if state.isLocked, let line = state.attendanceLine(for: session.currentUserID) {
                HStack(spacing: 6) {
                    if state.isAttendee(session.currentUserID) { StatusDot(color: DesignTokens.Colors.success).frame(width: 6, height: 6) }
                    Text(line).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        .accessibilityIdentifier("invite.attendance")
                }
                .frame(maxWidth: .infinity)
            }

            Text(state.progress(headcount: p.headcount))
                .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("invite.progress")

            PlacesSection(session: session, onToast: { msg in placesToast.show(msg) }, onChooseCity: {
                editSheet = EditSheet(startsOnCityPicker: true)
            })
        }
    }


    private func cardLabel(_ p: Proposal, _ state: LockState, _ caption: String?) -> String {
        if case .locked(let window, _, _) = state {
            let day = DateText.day(window.lowerBound, calendar: session.calendar, locale: .current)
            let time = DateText.timeRange(window, calendar: session.calendar, locale: .current)
            let line = state.attendanceLine(for: session.currentUserID).map { ", \($0)" } ?? ""
            return "\(p.displayTitle), locked, \(day), \(time)\(line)"
        }
        return [p.displayTitle, caption.map { $0.prefix(1).lowercased() + $0.dropFirst() }, state.progress(headcount: p.headcount)].compactMap { $0 }.joined(separator: ", ")
    }

    private var menu: some View {
        Menu {
            if let text = session.inviteText {
                ShareLink(item: text) { Label("Share invite", systemImage: "square.and.arrow.up") }
            }
            if session.isCreator, session.proposal?.status == .requesting {
                Button { editSheet = EditSheet() } label: { Label("Edit plan", systemImage: "pencil") }
                    .accessibilityIdentifier("invite.edit")
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(DesignTokens.Colors.text)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("invite.menu")
    }

    /// A link holder who is not on the plan yet joins on open (D3); PR2 signs in first.
    private func joinIfNeeded(force: Bool = false) {
        guard session.proposal != nil, !session.isRecipient, force || joinError == nil else { return }
        joinError = nil
        Task {
            do { try await session.join() } catch { joinError = UserFacingError.map(error, action: .join, creatorName: session.creatorName) }
        }
    }

    // MARK: Loading / error / gone (design 2.2A)

    private var loading: some View {
        VStack(alignment: .leading, spacing: 16) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.peachLight)
                .aspectRatio(4 / 3, contentMode: .fit)
            Capsule().fill(Color.skeleton).frame(width: 220, height: 14)
            Capsule().fill(Color.skeleton).frame(width: 140, height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading invite")
        .accessibilityIdentifier("invite.loading")
    }

    private func errorState(_ error: UserFacingError) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Couldn't open this invite").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityIdentifier("invite.error")
            Text("Check your connection and try again.").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
            Button { Task { await session.load() } } label: {
                Text("Retry").textStyle(.button).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.Colors.accentHover))
            }
            .accessibilityIdentifier("invite.retry")
            if let details = error.details {
                DisclosureGroup("Details") { Text(details).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted) }
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
            }
        }
    }

    private var gone: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("This plan is gone").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityIdentifier("invite.gone")
            Text("\(session.creatorName ?? "The host") may have cancelled it.").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
            Button(action: onGoToInvites) {
                Text("Go to Invites").textStyle(.button).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.Colors.accentHover))
            }
            .accessibilityIdentifier("invite.goToInvites")
        }
    }
}

/// The one coral 52pt pill (DESIGN.md button-primary).
struct PrimaryPill: View {
    let title: String
    var isBusy = false
    var fill: Color = DesignTokens.Colors.primary
    var foreground: Color = DesignTokens.Colors.onPrimary

    var body: some View {
        HStack(spacing: 8) {
            if isBusy { ProgressView().tint(foreground) }
            Text(title).textStyle(.button).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(Capsule().fill(fill))
        .contentShape(Capsule())
    }
}

/// An inline failure under the control that failed (design 2.3A): the mapped sentence in `error`,
/// a Retry link and a collapsed Details line with the raw text.
struct InlineError: View {
    let error: UserFacingError
    var retryTitle = "Retry"
    var onRetry: (() -> Void)?
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(error.message).textStyle(.caption).foregroundStyle(DesignTokens.Colors.errorText)
                    .accessibilityIdentifier("inlineError.message")
                if let onRetry {
                    Button(action: onRetry) {
                        Text(retryTitle).textStyle(.caption).foregroundStyle(DesignTokens.Colors.accentHover)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inlineError.retry")
                }
            }
            if let details = error.details {
                Button { showDetails.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Details").textStyle(.caption)
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down").imageScale(.small)
                    }
                    .foregroundStyle(DesignTokens.Colors.textMuted)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("inlineError.details")
                if showDetails {
                    Text(details).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        .accessibilityIdentifier("inlineError.detailsText")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Opens a proposal by id (Invites row, deep link, Home's header link): one session per screen (C9).
struct LockedInviteDestination: View {
    @State private var session: ProposalSession
    var onGoToInvites: () -> Void = {}

    init(store: ProposalStore, id: UUID, groupName: String = "", members: [HomeMember] = [], clock: @escaping () -> Date = { .now }, onGoToInvites: @escaping () -> Void = {}) {
        _session = State(initialValue: ProposalSession(store: store, groupName: groupName, members: members, proposalID: id, now: clock))
        self.onGoToInvites = onGoToInvites
    }

    var body: some View { LockedInviteView(session: session, onGoToInvites: onGoToInvites) }
}

#Preview("Invite, requesting (recipient)") {
    NavigationStack { LockedInviteView(session: ProposalSession(fixture: FixtureData.make(.lockedInvite))) }
}
#Preview("Invite, requesting (creator)") {
    NavigationStack { LockedInviteView(session: ProposalSession(fixture: FixtureData.make(.lockedInviteCreator))) }
}
#Preview("Invite, creator alone") {
    NavigationStack { LockedInviteView(session: ProposalSession(fixture: FixtureData.make(.creatorAlone))) }
}
#Preview("Invite, locked, you're in") {
    NavigationStack { LockedInviteView(session: ProposalSession(fixture: FixtureData.make(.lockedPlan))) }
}
#Preview("Invite, locked without you") {
    NavigationStack { LockedInviteView(session: ProposalSession(fixture: FixtureData.make(.lockedWithoutYou))) }
}
#Preview("Invite, late joiner") {
    NavigationStack { LockedInviteView(session: ProposalSession(fixture: FixtureData.make(.lockedLateJoiner))) }
}
