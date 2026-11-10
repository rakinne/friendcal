import SwiftUI
import FriendCalCore

/// "Tag along with Leo": the plans Leo is going to that you can still join.
///
///     Groups row / friend card ──> this sheet ──> [Tag along] ──> SocialSession.tagAlong ──> host is told
///                                       └── none to join ──> "Poke Leo" (the same poke as everywhere)
///
/// Only locked plans that have not ended are listed, and only ones you can already see: the server
/// shows a plan to the people on it, so this is never a window into plans you were not sent. A plan
/// you were on but not free for at the lock is the usual one here.
struct TagAlongSheet: View {
    let social: SocialSession
    let friend: Buddy
    var calendar: Calendar = .current
    /// A plan was joined: the shell can show it.
    var onJoined: (Proposal) -> Void = { _ in }

    private enum Phase: Equatable {
        case loading
        case plans([Proposal])
        case failed(UserFacingError)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var joining: UUID?
    @State private var refusal: UserFacingError?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                header
                switch phase {
                case .loading:
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).fill(DesignTokens.Colors.peachLight)
                        .frame(height: 148)
                        .accessibilityLabel("Loading plans")
                case .failed(let error):
                    InlineError(error: error, retryTitle: "Retry") { Task { await load() } }
                case .plans(let plans) where plans.isEmpty:
                    nothingYet
                case .plans(let plans):
                    if let refusal { InlineError(error: refusal, retryTitle: "OK") { self.refusal = nil } }
                    ForEach(plans) { plan($0) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.lg)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .toast(social.toasts)
        .sensoryFeedback(.impact, trigger: social.pokesSent)
        .task { await load() }
        .accessibilityIdentifier("tagAlong")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Tag along with").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
                Text(friend.name).textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            // The 44pt frame is inside the label: outside the Button it would only pad the layout.
            Button { dismiss() } label: {
                Text("Close").textStyle(.title)
                    .foregroundStyle(DesignTokens.Colors.accentHover)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("tagAlong.close")
        }
    }

    /// The plan as a ticket: the trail scene on top, title and time on ivory, one coral pill.
    private func plan(_ plan: Proposal) -> some View {
        let window = plan.lockedWindow
        let day = window.map { DateText.day($0.lowerBound, calendar: calendar, locale: .current) } ?? ""
        let time = window.map { DateText.timeRange($0, calendar: calendar, locale: .current) } ?? ""
        let who = TagAlongRules.whoIsIn(plan, friend: (friend.id, friend.name))
        return VStack(alignment: .leading, spacing: 0) {
            SceneArt(style: .tagAlong, anchor: 0.7)
                .frame(height: 76)
                .overlay(alignment: .bottomLeading) {
                    FriendAvatar(member: friend.face, size: 44, style: .label)
                        .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.surface, lineWidth: 2.5))
                        .padding(.leading, 14)
                        .offset(y: 14)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.title).textStyle(.rowName).foregroundStyle(DesignTokens.Colors.text)
                    .padding(.top, 14)
                Text(day).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                Text(time).textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                Text(who).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                PokePill(title: "Tag along", icon: "person.2.fill", isBusy: joining == plan.id) { join(plan) }
                    .disabled(joining != nil)
                    .padding(.top, 8)
                    .accessibilityLabel("Tag along to \(plan.title), \(day), \(time)")
                    .accessibilityIdentifier("tagAlong.join")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(DesignTokens.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .shadow(color: DesignTokens.Colors.shadow.opacity(0.12), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tagAlong.plan")
    }

    /// Nothing to join is a reason to poke, not a dead end.
    private var nothingYet: some View {
        let out = social.pokeCountdown(to: friend.id)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Nothing to tag along to yet").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityIdentifier("tagAlong.empty")
            Text("When \(friend.name) locks a plan you were sent, it lands here. Until then, a poke says you're up for something.")
                .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            PokePill(title: out.map { "Poked · \($0)" } ?? "Poke \(friend.name)", icon: "hand.point.up.left.fill",
                     style: out == nil ? .primary : .spent, isBusy: social.sending.contains(friend.id)) {
                Task { await social.poke(friend.id, name: friend.name) }
            }
            .accessibilityIdentifier("tagAlong.poke")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
            .stroke(DesignTokens.Colors.accentHover.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }

    private func load() async {
        do { phase = .plans(try await social.plans(with: friend.id)) } catch {
            phase = .failed(error as? UserFacingError ?? UserFacingError.map(error, action: .load))
        }
    }

    private func join(_ plan: Proposal) {
        guard joining == nil else { return }
        joining = plan.id
        refusal = nil
        Task {
            defer { joining = nil }
            do {
                let joined = try await social.tagAlong(plan.id, hostName: plan.createdBy == friend.id ? friend.name : nil)
                dismiss()
                onJoined(joined)
            } catch {
                refusal = error as? UserFacingError ?? UserFacingError.map(error, action: .tagAlong)
                // Whatever refused it, the list may be stale (it locked, it ended, you are in).
                if let fresh = try? await social.plans(with: friend.id) { phase = .plans(fresh) }
            }
        }
    }
}

#Preview("Tag along, a plan to join") {
    let fixture = FixtureData.withTagAlongPlan(FixtureData.make(.populated), now: FixtureClock.now())
    let social = SocialSession(store: FixtureData.store(fixture, clock: FixtureClock.now), now: FixtureClock.now)
    return TagAlongSheet(social: social, friend: Buddy(id: FixtureData.member("Leo").id, name: "Leo"))
}

#Preview("Tag along, nothing yet") {
    TagAlongSheet(social: .preview(), friend: Buddy(id: FixtureData.member("Maya").id, name: "Maya"))
}
