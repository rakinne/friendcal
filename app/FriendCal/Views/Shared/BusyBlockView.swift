import SwiftUI

/// Single component for rendering ANY Busy — manual, derived, or stealth.
/// Indistinguishable styling is the privacy invariant (P0). No avatar stack, no host label for stealth.
struct BusyBlockView: View {
    var sanitized: StealthService.SanitizedBusy
    var body: some View {
        HStack {
            Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 4)
            VStack(alignment: .leading) {
                Text("Busy").font(.subheadline).foregroundStyle(.secondary)
                Text(sanitized.range.lowerBound, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemGray6)))
        .accessibilityLabel("Busy")
    }
}
