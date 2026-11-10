import SwiftUI
import FriendCalCore

/// A friend opened up: their scene, status, away message, a 24-hour ribbon of today, and the two
/// actions. It is the sheet a tap opens and the preview a long-press lifts (variant D's peek card).
/// Poke and Tag along report through `onAction`; the screen sends them through `SocialSession`, the
/// same path as every other Poke in the app. While a poke to this friend is still out, the pill
/// shows its time left instead of offering a second.
struct FriendCard: View {
    enum Action { case poke, tagAlong }

    let buddy: Buddy
    let presence: Presence
    let text: RowText
    let ribbon: [RibbonSegment]
    let nowFraction: Double
    var showsActions = true
    /// "52 min left" while your poke to this friend is out.
    var pokeCountdown: String?
    var onAction: (Action) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            ZStack(alignment: .bottomLeading) {
                SceneArt(style: presence.scene, anchor: 0.7)
                    .frame(height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
                ZStack(alignment: .bottomTrailing) {
                    FriendAvatar(member: buddy.face, size: 72, style: .display)
                        .saturation(presence == .busy ? 0 : 1)
                        .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.surface, lineWidth: 3))
                    StatusSticker(presence: presence, size: 34).offset(x: 6, y: 6)
                }
                .padding(14)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(buddy.name).textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Text(presence.word.uppercased()).textStyle(.badge).tracking(0.8)
                        .foregroundStyle(presence.status == nil ? DesignTokens.Colors.textMuted : DesignTokens.Colors.accentHover)
                    if let time = text.time { Text(time).textStyle(.mono).foregroundStyle(DesignTokens.Colors.text) }
                }
                if let message = text.message {
                    Text(message).textStyle(.body).italic().foregroundStyle(DesignTokens.Colors.text)
                }
            }
            DayRibbonView(segments: ribbon, nowFraction: nowFraction)
            if showsActions {
                HStack(spacing: 10) {
                    actionPill(pokeCountdown.map { "Poked · \($0)" } ?? "Poke", icon: "hand.point.up.left.fill",
                               fill: pokeCountdown == nil ? DesignTokens.Colors.primary : DesignTokens.Colors.peachLight,
                               foreground: pokeCountdown == nil ? DesignTokens.Colors.onPrimary : DesignTokens.Colors.text) { onAction(.poke) }
                        .accessibilityIdentifier("friend.poke")
                    actionPill("Tag along", icon: "person.2.fill", fill: DesignTokens.Colors.accentHover) { onAction(.tagAlong) }
                        .accessibilityIdentifier("friend.tagAlong")
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.surface)
        .accessibilityElement(children: showsActions ? .contain : .combine)
    }

    private func actionPill(_ title: String, icon: String, fill: Color, foreground: Color = DesignTokens.Colors.onPrimary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).accessibilityHidden(true)
                Text(title).textStyle(.button).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Capsule().fill(fill))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Today as a 24-hour bar: busy time grey, their status in a glyph segment, a marker at now. Flat
/// and static on purpose (cheap to build, easy to read). It names no plan: all it can show is their
/// own live status and plain busy time.
struct DayRibbonView: View {
    let segments: [RibbonSegment]
    let nowFraction: Double

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).fill(DesignTokens.Colors.surface2)
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        let width = max(4, (seg.end - seg.start) * w)
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                            .fill(fill(seg.kind))
                            .overlay { glyph(seg.kind, width: width) }
                            .frame(width: width)
                            .offset(x: seg.start * w)
                            .padding(.vertical, 4)
                    }
                    Rectangle().fill(DesignTokens.Colors.text).frame(width: 2).offset(x: nowFraction * w - 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
            }
            .frame(height: 40)
            HStack {
                ForEach(["12 AM", "6 AM", "12 PM", "6 PM", "12 AM"], id: \.self) { label in
                    Text(label).textStyle(.badge).foregroundStyle(DesignTokens.Colors.textMuted)
                        .frame(maxWidth: .infinity, alignment: label == "12 AM" ? .leading : .center)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func fill(_ kind: RibbonSegment.Kind) -> Color {
        switch kind {
        case .busy: DesignTokens.Colors.busyGray
        case .status(.free): DesignTokens.Colors.warning
        case .status: DesignTokens.Colors.accentHover
        }
    }

    @ViewBuilder
    private func glyph(_ kind: RibbonSegment.Kind, width: CGFloat) -> some View {
        if case .status(let k) = kind, width > 26 {
            Image(systemName: k.symbolName).font(.system(size: 13, weight: .bold))
                .foregroundStyle(k == .free ? DesignTokens.Colors.text : DesignTokens.Colors.onPrimary)
        }
    }
}

/// Press feedback shared by Groups' coral and teal pills: a small scale, like Home's Poke.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("Friend card") {
    let now = Date()
    let status = FriendStatus(kind: .movies, message: "dune part three, no spoilers", since: now.addingTimeInterval(-2100), until: now.addingTimeInterval(5400))
    let presence = Presence.status(status)
    return FriendCard(buddy: Buddy(id: UUID(), name: "Leo"), presence: presence, text: presence.rowText(name: "Leo", now: now),
                      ribbon: DayRibbon.segments(status: status, busy: [], now: now), nowFraction: DayRibbon.fraction(of: now, now: now))
        .background(DesignTokens.Colors.background)
}
