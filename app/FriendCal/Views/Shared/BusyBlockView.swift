import SwiftUI

/// Single component for rendering ANY Busy — manual, derived, or stealth.
/// Indistinguishable styling is the privacy invariant (P0). No avatar stack, no host label for stealth.
struct BusyBlockView: View {
    var sanitized: StealthService.SanitizedBusy
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(DesignTokens.Colors.busyGray).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("Busy").font(.subheadline).foregroundStyle(DesignTokens.Colors.textMuted)
                Text(sanitized.range.lowerBound, style: .time)
                    .font(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            .padding(.leading, DesignTokens.Spacing.md)
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .padding(.trailing, DesignTokens.Spacing.md)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .shadow(color: DesignTokens.Colors.shadow.opacity(0.12), radius: 12, x: 0, y: 8)
        .accessibilityLabel("Busy")
    }
}
