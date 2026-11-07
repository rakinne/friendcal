import SwiftUI
import FriendCalCore

/// The invite artifact (issue #5 design 4.1A, 5.5A, 6.2A, 2.1A): a 4:3 text-free illustration
/// clipped at `Radius.lg`, a flat 60% `text` scrim over the bottom 40% with a 15% feather above it,
/// the hero headline and caption (or the locked date and window) in `onPrimary` inside the bottom
/// 40% with 20pt insets, and a 32pt badge top-right: `primary` padlock while requesting, `success`
/// check once locked, crossfading over 320ms (3.4A; immediate under Reduce Motion). Text inside the
/// card stops scaling at xxxLarge; the Large Content Viewer carries the full text.
struct InviteCard: View {
    let title: String
    let caption: String?
    let isLocked: Bool
    var lockedDay: String?
    var lockedTime: String?
    let accessibilityLabel: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let asset = "invite-card-brunch"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay { Image(Self.asset).resizable().aspectRatio(4 / 3, contentMode: .fill) }
            scrim
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .textStyle(.hero)
                    .foregroundStyle(DesignTokens.Colors.onPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("invite.title")
                if isLocked {
                    Text(lockedDay ?? "").textStyle(.title).foregroundStyle(DesignTokens.Colors.onPrimary)
                    Text(lockedTime ?? "").textStyle(.mono).foregroundStyle(DesignTokens.Colors.onPrimary)
                        .accessibilityIdentifier("invite.lockedTime")
                } else if let caption {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").imageScale(.small).accessibilityHidden(true)
                        Text(caption).textStyle(.caption).accessibilityIdentifier("invite.caption")
                    }
                    .foregroundStyle(DesignTokens.Colors.onPrimary)
                }
            }
            .padding(20)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: isLocked)
        }
        .overlay(alignment: .topTrailing) { badge.padding(12) }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .shadow(color: DesignTokens.Colors.shadow.opacity(0.12), radius: 12, x: 0, y: 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityShowsLargeContentViewer {
            Label(accessibilityLabel, systemImage: isLocked ? "checkmark.circle.fill" : "lock.fill")
        }
        .accessibilityIdentifier("invite.card")
    }

    /// Flat 60% `text` over the bottom 40%, feathered in over the 15% above it (delta O4).
    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: DesignTokens.Colors.text.opacity(0), location: 0.45),
            .init(color: DesignTokens.Colors.text.opacity(0.6), location: 0.60),
            .init(color: DesignTokens.Colors.text.opacity(0.6), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        .aspectRatio(4 / 3, contentMode: .fit)
        .allowsHitTesting(false)
    }

    private var badge: some View {
        ZStack {
            SwiftUI.Circle().fill(isLocked ? DesignTokens.Colors.success : DesignTokens.Colors.primary)
            Image(systemName: isLocked ? "checkmark" : "lock.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DesignTokens.Colors.onPrimary)
                .accessibilityIdentifier(isLocked ? "invite.badge.locked" : "invite.badge.lock")
        }
        .frame(width: 32, height: 32)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: isLocked)
        .accessibilityHidden(true)
    }
}

#Preview("Card, requesting") {
    InviteCard(title: "Brunch?", caption: "Locked until 1 more friend overlaps", isLocked: false,
               accessibilityLabel: "Brunch?, locked until 1 more friend overlaps")
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Card, locked") {
    InviteCard(title: "Brunch", caption: nil, isLocked: true, lockedDay: "Sat, Nov 14", lockedTime: "12:00–2:00 PM",
               accessibilityLabel: "Brunch, locked, Saturday November 14, 12 to 2, you're in")
        .padding(20).background(DesignTokens.Colors.background)
}
