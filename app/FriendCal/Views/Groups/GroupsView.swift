import SwiftUI
import FriendCalCore

/// The Groups tab (variant D, "Scene Rows + Live"): a buddy list where every friend is a tall row on
/// their own painted scene, with one live Moments line on top, your own row pinned first, crews as
/// folders and an automatic "Friends on FriendCal" folder for everyone not in a crew yet.
///
///     header + [Set status] ── Moments ── You (+ sticker tray) ── Start a crew ── folders ── rows
///                                                                      │              swipe: Poke / Tag along
///                                                                      ▼              long-press: peek card
///                                                          builder: tick friends,     tap: friend sheet
///                                                          name it, "Start crew with N"
///
/// It stays small-scale first: six friends fill the screen with personality, open seats are
/// invitations, and a person with no crew still sees every friend they know. Swipe and long-press are
/// accelerators; tap always opens the friend's card, so nothing hides behind a gesture. Poke goes
/// through `SocialSession.poke` from all four places it can start (swipe, long-press, the card, the
/// Moments line); Tag along opens the friend's joinable plans. Invites are still an honest stub.
struct GroupsView: View {
    let session: GroupsSession
    let social: SocialSession
    var onToast: (String) -> Void = { _ in }
    /// A plan was joined from the Tag along sheet.
    var onOpenPlan: (UUID) -> Void = { _ in }

    private struct StudioRequest: Identifiable {
        let id = UUID()
        var kind: StatusKind?
    }

    @State private var studio: StudioRequest?
    @State private var openCard: Buddy?
    @State private var draft: CrewDraft?
    @State private var tagAlong: Buddy?
    /// Set when the friend card asks for Tag along: one sheet has to finish leaving before the next opens.
    @State private var tagAlongAfterCard: Buddy?
    @State private var crewsStarted = 0
    /// A friend being removed through the card; the toast and the row follow the server's answer.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The list redraws each minute so "till 11:00 PM" statuses expire on time.
        TimelineView(.everyMinute) { _ in
            List {
                if draft == nil { browsing } else { building }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DesignTokens.Colors.background.ignoresSafeArea())
            // On the list, not the screen: an identifier on the whole screen also replaced the builder
            // bar's own ("groups.createCrew"), which sits beside the list in the safe-area inset.
            .accessibilityIdentifier("groups")
            .safeAreaInset(edge: .bottom, spacing: 0) { if draft != nil { builderBar } }
        }
        .sheet(item: $studio) { request in
            StatusStudioSheet(session: session, initialKind: request.kind,
                              onShared: { _ in onToast("Status shared") }, onCleared: { onToast("Status cleared") })
                .presentationDetents([.large])
                .presentationBackground(DesignTokens.Colors.background)
        }
        .sheet(item: $openCard, onDismiss: {
            tagAlong = tagAlongAfterCard
            tagAlongAfterCard = nil
        }) { buddy in
            card(buddy, showsActions: true)
                .presentationDetents([.medium, .large])
                .presentationBackground(DesignTokens.Colors.surface)
        }
        .sheet(item: $tagAlong) { buddy in
            TagAlongSheet(social: social, friend: buddy, calendar: session.calendar, onJoined: { onOpenPlan($0.id) })
                .presentationDetents([.medium, .large])
                .presentationBackground(DesignTokens.Colors.background)
        }
        .onAppear { session.setOnScreen(true) }
        .onDisappear { session.setOnScreen(false) }
        .task { await session.refresh() }
        .sensoryFeedback(.success, trigger: session.celebrations)
        .sensoryFeedback(.impact, trigger: social.pokesSent)
        .sensoryFeedback(.success, trigger: social.plansJoined)
        .sensoryFeedback(.success, trigger: session.statuses[session.you.id])
        .sensoryFeedback(.success, trigger: crewsStarted)
    }

    // MARK: Browsing

    @ViewBuilder
    private var browsing: some View {
        header.groupsRow(top: 8, bottom: 4)
        MomentsCard(moment: session.moment, onAction: perform)
            .groupsRow()
        youRow
        if session.myPresence.status == nil {
            StickerTray { studio = StudioRequest(kind: $0) }.groupsRow(top: 2, bottom: 8)
        }
        if !session.friends.isEmpty && session.crews.isEmpty {
            StartCrewCard { startBuilding() }.groupsRow(top: 6, bottom: 6)
        }
        if let error = session.loadError {
            InlineError(error: error, onRetry: { Task { await session.refresh() } })
                .groupsRow()
        } else if session.isLoadingRoster {
            Capsule().fill(Color.skeleton).frame(height: 56)
                .accessibilityElement(children: .ignore).accessibilityLabel("Loading your friends")
                .accessibilityIdentifier("groups.loading")
                .groupsRow()
        }
        ForEach(session.folders) { folder in
            FolderHeader(folder: folder, isExpanded: session.isExpanded(folder)) {
                withAnimation(.snappy) { session.toggle(folder) }
            }
            .groupsRow(top: 6, bottom: 0)
            if session.isExpanded(folder) {
                ForEach(folder.members) { friendRow($0) }
                seat(for: folder).groupsRow()
            }
        }
        if !session.friends.isEmpty && !session.crews.isEmpty {
            Button { startBuilding() } label: {
                Label("New crew", systemImage: "plus").textStyle(.title).foregroundStyle(DesignTokens.Colors.accentHover)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .groupsRow()
            .accessibilityIdentifier("groups.newCrew")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("FriendCal").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
                Text("Groups").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button { studio = StudioRequest(kind: nil) } label: {
                Text(session.myPresence.status == nil ? "Set status" : "Edit status")
                    .textStyle(.label).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 18).frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.Colors.primary))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("groups.setStatus")
        }
    }

    private var youRow: some View {
        let presence = session.myPresence
        let text = session.rowText(for: session.you)
        return Button { studio = StudioRequest(kind: nil) } label: {
            GroupRow(buddy: session.you, presence: presence, text: text, isYou: true)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken)
        .accessibilityIdentifier("groups.you")
        .groupsRow(top: 6, bottom: session.myPresence.status == nil ? 4 : 6)
    }

    private func friendRow(_ buddy: Buddy) -> some View {
        let presence = session.presence(of: buddy.id)
        let text = session.rowText(for: buddy)
        let poked = social.pokeCountdown(to: buddy.id)
        let highlighted = session.highlighted.contains(buddy.id)
        let removing = session.removing.contains(buddy.id)
        return Button { openCard = buddy } label: {
            GroupRow(buddy: buddy, presence: presence, text: text, poked: poked)
                // A new connection reads as a two-second ring; under Reduce Motion it is a plain
                // colour change with no animation.
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                    .stroke(DesignTokens.Colors.accent, lineWidth: 3).opacity(highlighted ? 1 : 0))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: highlighted)
                .opacity(removing ? 0.4 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(removing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(poked.map { "\(text.spoken), poked, \($0)" } ?? text.spoken)
        .accessibilityHint("Opens their card")
        .accessibilityIdentifier(highlighted ? "groups.row.highlighted" : "groups.row")
        .groupsRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { poke(buddy) } label: { Label("Poke", systemImage: "hand.point.up.left.fill") }
                .tint(DesignTokens.Colors.primary)
            Button { tagAlong = buddy } label: { Label("Tag along", systemImage: "person.2.fill") }
                .tint(DesignTokens.Colors.accentHover)
        }
        .contextMenu {
            Button { poke(buddy) } label: { Label("Poke \(buddy.name)", systemImage: "hand.point.up.left.fill") }
            Button { tagAlong = buddy } label: { Label("Tag along", systemImage: "person.2.fill") }
        } preview: {
            card(buddy, showsActions: false).frame(width: 340)
        }
    }

    private func card(_ buddy: Buddy, showsActions: Bool) -> some View {
        FriendCard(buddy: buddy, presence: session.presence(of: buddy.id), text: session.rowText(for: buddy),
                   ribbon: session.ribbon(for: buddy.id), nowFraction: DayRibbon.fraction(of: session.now, now: session.now, calendar: session.calendar),
                   showsActions: showsActions, pokeCountdown: social.pokeCountdown(to: buddy.id)) { action in
            switch action {
            case .tagAlong: tagAlongAfterCard = buddy
            case .poke: poke(buddy)
            case .remove: remove(buddy)
            }
            openCard = nil
        }
    }

    @ViewBuilder
    private func seat(for folder: GroupsFolder) -> some View {
        if session.loadError != nil || session.isLoadingRoster {
            // Never "no friends" while the first read is out or has failed.
            EmptyView()
        } else if folder.isAutomatic && folder.members.isEmpty {
            InviteSeatCard(title: "No friends here yet", subtitle: "Friends who join FriendCal land here. Invite one.") { onToast("Invites by link are coming soon") }
        } else {
            InviteSeatCard { onToast("Invites by link are coming soon") }
        }
    }

    // MARK: Building a crew

    @ViewBuilder
    private var building: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Start a crew").textStyle(.display).foregroundStyle(DesignTokens.Colors.text).accessibilityAddTraits(.isHeader)
            Spacer()
            Button { withAnimation(.snappy) { draft = nil } } label: {
                Text("Cancel").textStyle(.title).foregroundStyle(DesignTokens.Colors.accentHover)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("groups.cancelCrew")
        }
        .groupsRow(top: 8, bottom: 4)
        TextField(draft?.suggestedName(among: session.friends) ?? "My crew",
                  text: Binding(get: { draft?.name ?? "" }, set: { draft?.name = $0 }))
            .textStyle(.body)
            .submitLabel(.done)
            .padding(.horizontal, 14).frame(minHeight: 48)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
            .accessibilityLabel("Crew name")
            .accessibilityIdentifier("groups.crewName")
            .groupsRow()
        Text("Pick friends").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
            .groupsRow(top: 6, bottom: 0)
        ForEach(session.friends) { buddy in
            let on = draft?.isSelected(buddy.id) ?? false
            Button {
                withAnimation(.snappy(duration: 0.18)) { draft?.toggle(buddy.id) }
            } label: {
                GroupRow(buddy: buddy, presence: session.presence(of: buddy.id), text: session.rowText(for: buddy), ticked: on, animates: false)
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.rowText(for: buddy).spoken)
            .accessibilityValue(on ? "selected" : "not selected")
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("groups.pick")
            .sensoryFeedback(.selection, trigger: on)
            .groupsRow()
        }
    }

    private var builderBar: some View {
        let picked = draft?.selected.compactMap { session.buddy($0) } ?? []
        return HStack(spacing: 12) {
            HStack(spacing: -10) {
                ForEach(picked.prefix(4)) { b in
                    FriendAvatar(member: b.face, size: 34, style: .badge)
                        .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.background, lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
            Button { startCrew() } label: {
                Text(picked.isEmpty ? "Pick a friend" : "Start crew with \(picked.count)")
                    .textStyle(.button)
                    .foregroundStyle(picked.isEmpty ? DesignTokens.Colors.textMuted : DesignTokens.Colors.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Capsule().fill(picked.isEmpty ? DesignTokens.Colors.peachLight : DesignTokens.Colors.primary))
            }
            .buttonStyle(PressableStyle())
            .disabled(picked.isEmpty)
            .accessibilityIdentifier("groups.createCrew")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(DesignTokens.Colors.background.shadow(.drop(color: DesignTokens.Colors.shadow.opacity(0.18), radius: 10, y: -3)))
    }

    // MARK: Actions

    /// Every Poke on this screen. The rule, the toast and the haptic are `SocialSession`'s.
    private func poke(_ buddy: Buddy) {
        Task { await social.poke(buddy.id, name: buddy.name) }
    }

    /// The card confirmed Remove: the row dims, then leaves with a toast or comes back with the sentence.
    private func remove(_ buddy: Buddy) {
        Task {
            if let error = await session.remove(buddy) {
                onToast(error.message)
            } else {
                onToast("Removed \(buddy.name)")
            }
        }
    }

    private func perform(_ action: Moment.Action) {
        switch action {
        case .poke(let id, let name): Task { await social.poke(id, name: name) }
        case .setStatus: studio = StudioRequest(kind: nil)
        case .invite: onToast("Invites by link are coming soon")
        }
    }

    private func startBuilding() { withAnimation(.snappy) { draft = CrewDraft() } }

    private func startCrew() {
        guard let draft, let crew = session.createCrew(draft) else { return }
        withAnimation(.snappy) { self.draft = nil }
        crewsStarted += 1
        onToast("\(crew.name) is ready")
    }
}

private extension View {
    /// A Groups list row on the cream canvas: 20pt side margins, no separator, no row chrome.
    func groupsRow(top: CGFloat = 5, bottom: CGFloat = 5) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview("Groups, crew") {
    let fixture = FixtureData.make(.populated)
    return GroupsView(session: GroupsSession(seed: .make(fixture: fixture, youID: nil, scenario: .crew, now: .now)), social: .preview())
}

#Preview("Groups, no crew yet") {
    let fixture = FixtureData.make(.populated)
    return GroupsView(session: GroupsSession(seed: .make(fixture: fixture, youID: nil, scenario: .friends, now: .now)), social: .preview())
}

#Preview("Groups, alone") {
    GroupsView(session: GroupsSession(seed: .make(fixture: FixtureData.make(.noFriends), youID: nil, now: .now)), social: .preview(.noFriends))
}
