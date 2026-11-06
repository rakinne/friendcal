import SwiftUI
import FriendCalCore

/// Poke (coral, dominant) and Share slot (teal, quieter), 52pt pills at a 1.38 : 1 split.
/// Poke is an honest stub: impact haptic + toast (D20). Share is a native ShareLink with the
/// selected slot (X9), disabled with a VoiceOver hint when there is nothing to share (X6, X10).
struct ActionRow: View {
    var isLoading = false
    var shareText: String?
    var shareDisabledHint: String?
    var onPoke: () -> Void = {}

    @State private var pokes = 0

    var body: some View {
        GeometryReader { geo in
            let poke = (geo.size.width - 10) * 1.38 / 2.38
            HStack(spacing: 10) {
                if isLoading {
                    Capsule().fill(Color.skeleton).frame(width: poke)
                    Capsule().fill(Color.skeleton)
                } else {
                    Button {
                        pokes += 1
                        onPoke()
                    } label: {
                        pill(icon: "hand.point.up.left.fill", text: "Poke", fill: DesignTokens.Colors.primary)
                    }
                    .frame(width: poke)
                    .accessibilityIdentifier("home.poke")
                    share
                }
            }
        }
        .frame(height: 52)
        .buttonStyle(PressScale())
        .sensoryFeedback(.impact, trigger: pokes)
        .accessibilityElement(children: isLoading ? .ignore : .contain)
        .accessibilityLabel(isLoading ? "Loading actions" : "")
    }

    @ViewBuilder
    private var share: some View {
        if let shareText {
            ShareLink(item: shareText) {
                pill(icon: "square.and.arrow.up", text: "Share slot", fill: DesignTokens.Colors.accentHover)
            }
            .accessibilityIdentifier("home.share")
        } else {
            Button {} label: {
                pill(icon: "square.and.arrow.up", text: "Share slot", fill: DesignTokens.Colors.peachLight, foreground: DesignTokens.Colors.textMuted)
            }
            .disabled(true)
            .accessibilityHint(shareDisabledHint ?? "")
            .accessibilityIdentifier("home.share")
        }
    }

    private func pill(icon: String, text: String, fill: Color, foreground: Color = DesignTokens.Colors.onPrimary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).imageScale(.medium).accessibilityHidden(true)
            Text(text).textStyle(.button).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(fill))
        .contentShape(Capsule())
    }
}

/// DESIGN.md: active scale 0.98.
private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#Preview("Actions, shareable") {
    ActionRow(shareText: "Brunch? Sat, Nov 14 · 12:00-5:00 PM works for 13 of 15")
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Actions, nothing selected") {
    ActionRow(shareText: nil, shareDisabledHint: "Pick a time first")
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Actions, loading") {
    ActionRow(isLoading: true).padding(20).background(DesignTokens.Colors.background)
}
