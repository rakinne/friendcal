import SwiftUI
import Combine

/// Real-time heatmap converging as recipients tap free slots.
/// Ember coral = best/fully converging, peach = partial, warm border = none.
/// Debounce recompute 500ms (now: Combine debounce on rows publisher; caller should throttle writes).
struct HeatmapView: View {
    var rows: [HeatmapRow]
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ForEach(rows, id: \.date) { row in
                HStack {
                    Text(row.date, style: .date).font(.caption).monospacedDigit()
                    Spacer()
                    Text("\(row.freeCount)/\(row.totalRecipients) free").font(.caption)
                    SwiftUI.Circle().fill(color(for: row.level)).frame(width: 12, height: 12)
                        .scaleEffect(row.level == .green && !reduceMotion ? 1.08 : 1)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: row.level)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(DesignTokens.Colors.border, lineWidth: 1))
            }
        }
    }
    func color(for level: HeatmapRow.Level) -> Color {
        switch level {
        case .green: return DesignTokens.Colors.primary
        case .yellow: return DesignTokens.Colors.peach
        case .red: return DesignTokens.Colors.border
        }
    }
}
