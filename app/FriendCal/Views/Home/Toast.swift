import SwiftUI
import FriendCalCore

/// One bottom toast for honest stubs (D20, D21): auto-dismisses after 2.5s and is announced
/// to VoiceOver.
@Observable
final class ToastCenter {
    private(set) var message: String?
    private var dismissal: Task<Void, Never>?

    func show(_ text: String) {
        message = text
        AccessibilityNotification.Announcement(text).post()
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        Text(message)
            .textStyle(.label)
            .foregroundStyle(DesignTokens.Colors.surface)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 10)
            .background(Capsule().fill(DesignTokens.Colors.text))
            .shadow(color: DesignTokens.Colors.shadow.opacity(0.25), radius: 12, y: 6)
            .accessibilityIdentifier("toast")
    }
}

extension View {
    /// Presents the center's toast above the bottom safe area (so above the tab bar, D34).
    func toast(_ center: ToastCenter) -> some View {
        overlay(alignment: .bottom) {
            if let message = center.message {
                ToastView(message: message)
                    .padding(.bottom, DesignTokens.Spacing.sm)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: center.message)
    }
}

#Preview("Toast") {
    ToastView(message: "Poke is coming soon")
        .padding()
        .background(DesignTokens.Colors.background)
}
