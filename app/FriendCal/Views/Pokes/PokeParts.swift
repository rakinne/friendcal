import SwiftUI
import FriendCalCore

/// One poke, or one tag along, as a tall row: the friend on a painted scene, the words on an opaque
/// ivory plate (so text never depends on the art, as on Groups), an optional fuse along the bottom
/// edge, and an optional row of actions underneath.
///
/// The scene row is ONE VoiceOver element with one spoken sentence; the actions stay separate
/// elements after it, so nothing is reachable only by sight.
struct PokeCard<Actions: View>: View {
    let person: HomeMember
    let title: String
    /// "POKED YOU", "SEEN", "TAGGING ALONG": the state, as a word. Never hue alone (D25).
    let word: String
    /// "52 min left", "12 min ago" (mono).
    let time: String
    /// "about Brunch", "joined Tacos" (italic).
    var detail: String?
    let scene: SceneStyle
    /// 0...1 of the hour left; nil for anything that is not burning down.
    var fuse: Double?
    /// Finished pokes sit back: grey plate, still scene, desaturated face.
    var isQuiet = false
    let spoken: String
    /// Identifies the card itself. It is set here, not on the whole `PokeCard` from outside, because an
    /// identifier on the outer view would also replace the identifiers of the buttons in `actions`.
    var identifier: String?
    @ViewBuilder var actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                FriendAvatar(member: person, size: 56, style: .title)
                    .saturation(isQuiet ? 0 : 1)
                    .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.surface, lineWidth: 2.5))
                    .frame(width: 88)
                Spacer(minLength: 0)
                plate
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.56 }
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
            }
            .frame(minHeight: 92)
            .background { SceneArt(style: scene, anchor: 0.24, animates: !isQuiet) }
            .overlay(alignment: .bottomLeading) { if let fuse { FuseBar(fraction: fuse) } }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
            .shadow(color: DesignTokens.Colors.shadow.opacity(isQuiet ? 0 : 0.12), radius: 12, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityIdentifier(identifier ?? "")
            actions()
        }
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .textStyle(.rowName)
                .foregroundStyle(DesignTokens.Colors.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // The word and the time wrap onto two lines at large type instead of truncating.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { wordText; timeText }
                VStack(alignment: .leading, spacing: 1) { wordText; timeText }
            }
            if let detail {
                Text(detail)
                    .textStyle(.body)
                    .italic()
                    .foregroundStyle(DesignTokens.Colors.text)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
            .fill(isQuiet ? DesignTokens.Colors.surface2 : DesignTokens.Colors.surface))
    }

    private var wordText: some View {
        Text(word).textStyle(.badge).tracking(0.8).lineLimit(1)
            .foregroundStyle(isQuiet ? DesignTokens.Colors.textMuted : DesignTokens.Colors.accentHover)
    }

    private var timeText: some View {
        Text(time).textStyle(.mono).foregroundStyle(DesignTokens.Colors.text).lineLimit(1).minimumScaleFactor(0.85)
    }
}

/// The hour, burning down along a live poke's bottom edge. Coral on a peach track; it shrinks toward
/// the leading edge. Decorative: the countdown is on the plate in words.
struct FuseBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(DesignTokens.Colors.peach.opacity(0.6))
                Rectangle().fill(DesignTokens.Colors.primary)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                    .animation(.linear(duration: 0.6), value: fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The one live line at the top of the tab. The dot beats once when the line changes, like the dot
/// on Groups' Moments, and is coral while something is waiting for you.
struct PokeHeadline: View {
    let text: String
    let isLive: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(isLive ? DesignTokens.Colors.primary : DesignTokens.Colors.accent)
                .symbolEffect(.bounce, options: .nonRepeating, value: text)
                .accessibilityHidden(true)
            Text(text).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .animation(.snappy, value: text)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pokes.headline")
    }
}

struct PokeSectionHeader: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).textStyle(.rowName).foregroundStyle(DesignTokens.Colors.text)
            if let count {
                Text("(\(count))").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A 44pt pill for a poke's two answers and the sheets' actions. Primary is the coral fill, quiet
/// the teal outline; while busy it keeps its size and dims, so the row does not jump.
struct PokePill: View {
    enum Style { case primary, quiet, spent }

    let title: String
    var icon: String?
    var style: Style = .primary
    var isBusy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).imageScale(.small).accessibilityHidden(true) }
                Text(title).textStyle(.label).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Capsule().fill(fill))
            .overlay(Capsule().stroke(style == .quiet ? DesignTokens.Colors.accentHover : Color.clear, lineWidth: 1.5))
            .opacity(isBusy ? 0.55 : 1)
        }
        .buttonStyle(PressableStyle())
        .disabled(isBusy)
    }

    private var fill: Color {
        switch style {
        case .primary: DesignTokens.Colors.primary
        case .quiet: DesignTokens.Colors.surface
        case .spent: DesignTokens.Colors.peachLight
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: DesignTokens.Colors.onPrimary
        case .quiet: DesignTokens.Colors.accentHover
        case .spent: DesignTokens.Colors.text
        }
    }
}

/// Coral-edged ivory, like "Start a crew": a poke lasts an hour, so a missed push is a missed poke.
struct NotificationCard: View {
    let isDenied: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bell.badge.fill").font(.system(size: 20)).foregroundStyle(DesignTokens.Colors.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Don't miss a poke").textStyle(.rowName).foregroundStyle(DesignTokens.Colors.text)
                    Text(isDenied ? "Notifications are off for FriendCal. Pokes fade in an hour." : "Pokes fade in an hour. Get them as they land.")
                        .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(isDenied ? "Settings" : "Turn on").textStyle(.label).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.Colors.primary))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).stroke(DesignTokens.Colors.primary, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isDenied ? "Don't miss a poke. Notifications are off. Opens Settings" : "Don't miss a poke. Turn on notifications")
        .accessibilityIdentifier("pokes.notifications")
    }
}

/// The empty tab: a dashed seat, like Groups' open seat, that leads to the people you can poke.
struct EmptyPokesCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "hand.point.up.left.fill").font(.system(size: 20)).foregroundStyle(DesignTokens.Colors.accentHover)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("No pokes yet").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                    Text("Poke a friend from Groups").textStyle(.body).foregroundStyle(DesignTokens.Colors.accentHover)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .stroke(DesignTokens.Colors.accentHover.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("No pokes yet. Poke a friend from Groups")
        .accessibilityIdentifier("pokes.empty")
    }
}

#Preview("Poke cards") {
    let leo = HomeMember(id: FixtureData.fixtureID(3), name: "Leo", isOnline: true, isActive: false)
    return ScrollView {
        VStack(spacing: 12) {
            PokeHeadline(text: "Leo poked you. 52 min left.", isLive: true)
            PokeCard(person: leo, title: "Leo", word: "POKED YOU", time: "52 min left", detail: "about Brunch", scene: .poke, fuse: 0.86,
                     spoken: "Leo poked you") {
                HStack(spacing: 10) {
                    PokePill(title: "Poke back", icon: "hand.point.up.left.fill") {}
                    PokePill(title: "Got it", icon: "checkmark", style: .quiet) {}
                }
            }
            PokeCard(person: leo, title: "Leo", word: "SEEN", time: "4 min ago", scene: .pokeSeen, spoken: "") { EmptyView() }
            PokeCard(person: leo, title: "Leo", word: "TAGGING ALONG", time: "just now", detail: "joined Tacos", scene: .tagAlong, spoken: "") { EmptyView() }
            PokeCard(person: leo, title: "Leo", word: "FADED", time: "2 h ago", scene: .quiet, isQuiet: true, spoken: "") { EmptyView() }
            NotificationCard(isDenied: false) {}
            EmptyPokesCard {}
        }
        .padding(20)
    }
    .background(DesignTokens.Colors.background)
}
