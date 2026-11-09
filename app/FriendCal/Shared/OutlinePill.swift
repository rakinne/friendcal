import SwiftUI

/// Outlined pill (DESIGN.md button-outline): ivory fill, 1.5pt accentHover border, pill radius, 44pt min.
/// Voted state: accentHover fill with onPrimary label + check.
public struct OutlinePill: View {
    let title: String
    var isVoted: Bool = false
    var fullWidth: Bool = false
    var isBusy: Bool = false

    public init(title: String, isVoted: Bool = false, fullWidth: Bool = false, isBusy: Bool = false) {
        self.title = title; self.isVoted = isVoted; self.fullWidth = fullWidth; self.isBusy = isBusy
    }

    public var body: some View {
        HStack(spacing: 6) {
            if isBusy { ProgressView().tint(isVoted ? DesignTokens.Colors.onPrimary : DesignTokens.Colors.accentHover) }
            if isVoted {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(title)
                .textStyle(fullWidth ? .button : .label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isVoted ? DesignTokens.Colors.onPrimary : DesignTokens.Colors.accentHover)
        .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isVoted ? DesignTokens.Colors.accentHover : DesignTokens.Colors.surface)
        )
        .overlay(
            Capsule()
                .stroke(isVoted ? Color.clear : DesignTokens.Colors.accentHover, lineWidth: 1.5)
        )
        .contentShape(Capsule())
    }
}

#Preview("Outline pills") {
    VStack(spacing: 12) {
        OutlinePill(title: "Vote")
        OutlinePill(title: "Voted", isVoted: true)
        OutlinePill(title: "Suggest a place", fullWidth: true)
        OutlinePill(title: "Choose a city", fullWidth: true)
    }
    .padding()
    .background(DesignTokens.Colors.background)
}
