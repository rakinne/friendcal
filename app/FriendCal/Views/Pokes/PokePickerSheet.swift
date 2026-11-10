import SwiftUI
import FriendCalCore

/// Home's Poke: "Who needs a poke?"
///
/// Home shows a whole group, so its Poke button cannot know who you mean. This sheet lists the
/// people on the plan with the ones who have not marked a time first, because nudging them is what
/// a poke was invented for (premise 6: it replaces "@ them three times" in the group thread). Each
/// row's pill is the same `SocialSession.poke` Groups uses, carrying the plan as context; "Poke all"
/// is that call once per waiting friend.
struct PokePickerSheet: View {
    let social: SocialSession
    let targets: [PokeTarget]
    /// What the pokes are about. Nil when Home has no plan.
    let planID: UUID?
    let planTitle: String?
    /// Faces for the rows; a target with none still gets initials from its name.
    var faces: [UUID: HomeMember] = [:]

    @Environment(\.dismiss) private var dismiss
    @State private var pokingAll = false

    private var waiting: [PokeTarget] { targets.filter(\.isWaiting) }
    private var unpokedWaiting: [PokeTarget] { waiting.filter { social.livePoke(to: $0.id) == nil } }

    var body: some View {
        TimelineView(.everyMinute) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    header
                    if targets.isEmpty {
                        Text("Nobody to poke yet. Invite a friend to a plan first.")
                            .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                            .padding(.vertical, DesignTokens.Spacing.md)
                            .accessibilityIdentifier("pokePicker.empty")
                    }
                    ForEach(targets) { row($0) }
                }
                .padding(.horizontal, 20)
                .padding(.top, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.lg)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) { if waiting.count > 1 { pokeAllBar } }
        }
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .toast(social.toasts)
        .sensoryFeedback(.impact, trigger: social.pokesSent)
        .accessibilityIdentifier("pokePicker")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                if let planTitle {
                    Text(planTitle).textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
                }
                Text("Who needs a poke?").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            // The 44pt frame is inside the label: outside the Button it would only pad the layout.
            Button { dismiss() } label: {
                Text("Done").textStyle(.title)
                    .foregroundStyle(DesignTokens.Colors.accentHover)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("pokePicker.done")
        }
    }

    private func row(_ target: PokeTarget) -> some View {
        let out = social.pokeCountdown(to: target.id)
        let face = faces[target.id] ?? HomeMember(id: target.id, name: target.name, isOnline: false, isActive: false)
        return HStack(spacing: 12) {
            FriendAvatar(member: face, size: 44, style: .label)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name).textStyle(.title).foregroundStyle(DesignTokens.Colors.text).lineLimit(1)
                if let out {
                    Text(out).textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                } else if target.isWaiting {
                    Text("hasn't picked a time").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            PokePill(title: out == nil ? "Poke" : "Poked", icon: "hand.point.up.left.fill", style: out == nil ? .primary : .spent,
                     isBusy: social.sending.contains(target.id) || pokingAll) {
                Task { await social.poke(target.id, name: target.name, about: planID) }
            }
            .frame(width: 112)
            .accessibilityLabel(out.map { "\(target.name) is poked, \($0)" } ?? "Poke \(target.name)")
            .accessibilityIdentifier("pokePicker.poke")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 64)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
            .stroke(target.isWaiting && out == nil ? DesignTokens.Colors.primary : DesignTokens.Colors.border, lineWidth: target.isWaiting && out == nil ? 1.5 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pokePicker.row")
    }

    private var pokeAllBar: some View {
        let left = unpokedWaiting
        return Button {
            pokingAll = true
            Task {
                await social.poke(all: left, about: planID)
                pokingAll = false
            }
        } label: {
            Text(left.isEmpty ? "Everyone waiting is poked" : "Poke all \(left.count) who haven't answered")
                .textStyle(.button)
                .foregroundStyle(left.isEmpty ? DesignTokens.Colors.textMuted : DesignTokens.Colors.onPrimary)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Capsule().fill(left.isEmpty ? DesignTokens.Colors.peachLight : DesignTokens.Colors.primary))
        }
        .buttonStyle(PressableStyle())
        .disabled(left.isEmpty || pokingAll)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(DesignTokens.Colors.background.shadow(.drop(color: DesignTokens.Colors.shadow.opacity(0.18), radius: 10, y: -3)))
        .accessibilityIdentifier("pokePicker.all")
    }
}

#Preview("Who needs a poke?") {
    let fixture = FixtureData.make(.populated)
    let people = fixture.members.prefix(6).map { (id: $0.id, name: $0.name) }
    return PokePickerSheet(social: .preview(), targets: PokeTarget.order(members: Array(people), answered: [people[1].id, people[2].id], me: people[0].id, isCollecting: true),
                           planID: fixture.proposal?.id, planTitle: "Brunch?",
                           faces: Dictionary(uniqueKeysWithValues: fixture.members.map { ($0.id, $0) }))
}
