import SwiftUI

/// Real-time heatmap converging as recipients tap free slots.
/// Green = all free, yellow = partial, red = none. Debounce recompute 500ms (P2 perf).
struct HeatmapView: View {
    var rows: [HeatmapRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.date) { row in
                HStack {
                    Text(row.date, style: .date)
                    Spacer()
                    Text("\(row.freeCount)/\(row.totalRecipients) free")
                    Circle().fill(color(for: row.level)).frame(width: 12, height: 12)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemGray6)))
            }
        }
    }
    func color(for level: HeatmapRow.Level) -> Color {
        switch level { case .green: return .green; case .yellow: return .yellow; case .red: return .red }
    }
}
