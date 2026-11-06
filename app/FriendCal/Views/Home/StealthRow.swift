import SwiftUI
import FriendCalCore

/// "Stealth until you're ready" (D21). Stealth isn't wired yet, so the native Toggle stays off and
/// a tap explains that instead of showing a false privacy state.
struct StealthRow: View {
    var isLoading = false
    var onTap: () -> Void = {}

    var body: some View {
        Group {
            if isLoading {
                HStack {
                    Capsule().fill(Color.skeleton).frame(width: 200, height: 14)
                    Spacer()
                    Capsule().fill(Color.skeleton).frame(width: 51, height: 31)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading stealth setting")
            } else {
                Toggle(isOn: Binding(get: { false }, set: { _ in onTap() })) {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash").foregroundStyle(DesignTokens.Colors.text).accessibilityHidden(true)
                        Text("Stealth until you're ready").textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                        Image(systemName: "info.circle").imageScale(.small).foregroundStyle(DesignTokens.Colors.textMuted).accessibilityHidden(true)
                    }
                }
                .tint(DesignTokens.Colors.accent)
                .accessibilityIdentifier("home.stealth")
            }
        }
        .frame(minHeight: 52)
        .overlay(alignment: .top) { Rectangle().fill(DesignTokens.Colors.border).frame(height: 1) }
    }
}

#Preview("Stealth") { StealthRow().padding(20).background(DesignTokens.Colors.background) }
#Preview("Stealth, loading") { StealthRow(isLoading: true).padding(20).background(DesignTokens.Colors.background) }
