import SwiftUI
import FriendCalCore

/// The Pokes tab: everything aimed at you, and everything you have out.
///
///     header ── headline ── [Turn on notifications] ── For you ── Tagging along ── Sent ── Earlier
///                                                        │              │
///                                                  Poke back / Got it   tap: opens the plan
///
/// It borrows Groups' language on purpose (tall rows on a painted scene, an ivory plate for the
/// words, one live line on top), because a poke is a friend doing something, the same as a status.
/// A live poke's row carries a fuse along its bottom edge that burns down across its hour.
///
/// Nothing here sends or answers a poke itself: both buttons call `SocialSession`, the same path
/// Home and Groups use, so "Poke back" is just a poke and acknowledges theirs on the server.
struct PokesView: View {
    let social: SocialSession
    /// A tag along opens the plan it joined.
    var onOpenPlan: (UUID) -> Void = { _ in }
    var onGoToGroups: () -> Void = {}

    var body: some View {
        // Redraws on the minute so countdowns tick and a poke leaves "For you" when its hour is up.
        TimelineView(.everyMinute) { _ in
            let feed = social.feed
            List {
                header.pokesRow(top: 8, bottom: 4)
                PokeHeadline(text: feed.headline(names: social.name(of:), now: social.now), isLive: !feed.forYou.isEmpty)
                    .pokesRow()
                if social.notifications == .notDetermined || social.notifications == .denied {
                    NotificationCard(isDenied: social.notifications == .denied) { Task { await social.turnOnNotifications() } }
                        .pokesRow(top: 6, bottom: 6)
                }
                if !social.hasLoaded {
                    if let error = social.loadError { failed(error).pokesRow() } else { skeleton }
                } else if feed.isEmpty {
                    EmptyPokesCard(action: onGoToGroups).pokesRow(top: 6, bottom: 6)
                } else {
                    sections(feed)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DesignTokens.Colors.background.ignoresSafeArea())
            .refreshable { await social.refresh() }
        }
        .sensoryFeedback(.impact, trigger: social.pokesSent)
        .accessibilityIdentifier("pokes")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FriendCal").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
            Text("Pokes").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottomLeading)
    }

    @ViewBuilder
    private func sections(_ feed: PokeFeed) -> some View {
        if !feed.forYou.isEmpty {
            PokeSectionHeader(title: "For you", count: feed.forYou.count).pokesRow(top: 8, bottom: 0)
            ForEach(feed.forYou) { poke in
                let name = social.name(of: poke.fromID)
                PokeCard(person: HomeMember(id: poke.fromID, name: name, isOnline: true, isActive: false),
                         title: name, word: PokeText.receivedWord(poke.state(at: social.now)),
                         time: PokeText.timeLine(poke, now: social.now), detail: social.planTitle(of: poke).map { "about \($0)" },
                         scene: .poke, fuse: poke.fuse(at: social.now),
                         spoken: PokeText.spokenReceived(name: name, plan: social.planTitle(of: poke), poke: poke, now: social.now),
                         identifier: "pokes.forYou") {
                    HStack(spacing: 10) {
                        PokePill(title: "Poke back", icon: "hand.point.up.left.fill", style: .primary,
                                 isBusy: social.sending.contains(poke.fromID)) {
                            Task { await social.poke(poke.fromID, name: name, about: poke.proposalID) }
                        }
                        .accessibilityIdentifier("pokes.pokeBack")
                        PokePill(title: "Got it", icon: "checkmark", style: .quiet, isBusy: social.answering.contains(poke.id)) {
                            Task { await social.acknowledge(poke.id) }
                        }
                        .accessibilityIdentifier("pokes.gotIt")
                    }
                }
                .pokesRow()
            }
        }
        if !feed.tagAlongs.isEmpty {
            PokeSectionHeader(title: "Tagging along", count: feed.tagAlongs.count).pokesRow(top: 8, bottom: 0)
            ForEach(feed.tagAlongs) { notice in
                let name = social.name(of: notice.userID)
                Button { onOpenPlan(notice.proposalID) } label: {
                    PokeCard(person: HomeMember(id: notice.userID, name: name, isOnline: true, isActive: false),
                             title: name, word: "TAGGING ALONG", time: PokeText.ago(notice.createdAt, now: social.now),
                             detail: "joined \(notice.planTitle)", scene: .tagAlong, fuse: nil,
                             spoken: "\(name) is tagging along to \(notice.planTitle)") { EmptyView() }
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Opens the plan")
                .accessibilityIdentifier("pokes.tagAlong")
                .pokesRow()
            }
        }
        if !feed.sent.isEmpty {
            PokeSectionHeader(title: "Sent", count: feed.sent.count).pokesRow(top: 8, bottom: 0)
            ForEach(feed.sent) { poke in
                let name = social.name(of: poke.toID)
                let state = poke.state(at: social.now)
                PokeCard(person: HomeMember(id: poke.toID, name: name, isOnline: true, isActive: false),
                         title: name, word: PokeText.sentWord(state), time: PokeText.timeLine(poke, now: social.now),
                         detail: social.planTitle(of: poke).map { "about \($0)" },
                         scene: poke.isLive(at: social.now) ? .poke : .pokeSeen, fuse: poke.isLive(at: social.now) ? poke.fuse(at: social.now) : nil,
                         spoken: PokeText.spokenSent(name: name, poke: poke, now: social.now)) { EmptyView() }
                    .accessibilityIdentifier("pokes.sent")
                    .pokesRow()
            }
        }
        if !feed.earlier.isEmpty {
            PokeSectionHeader(title: "Earlier", count: nil).pokesRow(top: 8, bottom: 0)
            ForEach(feed.earlier) { poke in
                let mine = poke.fromID == social.me
                let other = mine ? poke.toID : poke.fromID
                let name = social.name(of: other)
                let state = poke.state(at: social.now)
                PokeCard(person: HomeMember(id: other, name: name, isOnline: false, isActive: false),
                         title: name, word: mine ? PokeText.sentWord(state) : PokeText.receivedWord(state),
                         time: PokeText.timeLine(poke, now: social.now), detail: nil,
                         scene: state == .expired ? .quiet : .pokeSeen, fuse: nil, isQuiet: true,
                         spoken: mine ? PokeText.spokenSent(name: name, poke: poke, now: social.now)
                                      : PokeText.spokenReceived(name: name, plan: nil, poke: poke, now: social.now)) { EmptyView() }
                    .accessibilityIdentifier("pokes.earlier")
                    .pokesRow()
            }
        }
    }

    private var skeleton: some View {
        ForEach(0..<3, id: \.self) { _ in
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .fill(DesignTokens.Colors.peachLight)
                .frame(height: 92)
                .pokesRow()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading pokes")
    }

    private func failed(_ error: UserFacingError) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Couldn't load your pokes").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
            Text("Check your connection and try again.").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
            Button { Task { await social.refresh() } } label: {
                Text("Retry").textStyle(.button).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.Colors.accentHover))
            }
            .buttonStyle(PressableStyle())
            .accessibilityIdentifier("pokes.retry")
        }
        .accessibilityIdentifier("pokes.error")
    }
}

extension View {
    /// A row on the cream canvas, like Groups: 20pt side margins, no separator, no row chrome.
    func pokesRow(top: CGFloat = 5, bottom: CGFloat = 5) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#Preview("Pokes, busy") {
    let fixture = FixtureData.make(.populated)
    let store = FixtureData.store(fixture, clock: FixtureClock.now)
    FixtureData.seedPokes(into: store, fixture: fixture, now: FixtureClock.now())
    let social = SocialSession(store: store, now: FixtureClock.now)
    return PokesView(social: social).task { await social.refresh() }
}

#Preview("Pokes, empty") {
    let social = SocialSession.preview()
    return PokesView(social: social).task { await social.refresh() }
}
