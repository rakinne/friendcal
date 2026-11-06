import SwiftUI
import FriendCalCore

/// Interim list rendering of heatmap cells with any shared time, for the debug proposal flow.
/// Replaced by HeatmapCard (issue #4, D1).
struct HeatmapView: View {
    var weeks: [HeatmapWeek]
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ForEach(weeks.flatMap(\.cells).filter { $0.isEnabled && $0.commonCount > 0 }) { cell in
                HStack {
                    Text(cell.day, style: .date).font(.caption).monospacedDigit()
                    Text(String(describing: cell.daypart)).font(.caption)
                    Spacer()
                    Text("\(cell.commonCount)/\(cell.total) free").font(.caption)
                    SwiftUI.Circle().fill(color(for: cell.ramp)).frame(width: 12, height: 12)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(cell.isBest ? DesignTokens.Colors.text : DesignTokens.Colors.border, lineWidth: cell.isBest ? 2 : 1))
            }
        }
    }
    func color(for ramp: HeatmapRamp?) -> Color {
        switch ramp {
        case .primary: return DesignTokens.Colors.primary
        case .orange: return Color(hex: "#FF6A32")
        case .peach: return DesignTokens.Colors.peach
        case .peachLight, nil: return DesignTokens.Colors.peachLight
        }
    }
}
