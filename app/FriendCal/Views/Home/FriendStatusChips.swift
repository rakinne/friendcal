import SwiftUI
import FriendCalCore

/// Who is in or out for the selected cell (D22, D35), from its roster (X2). More than 4 scroll
/// horizontally, with the last chip clipped at the edge (D19). HomeView hides the row when nothing
/// is selected.
struct FriendStatusChips: View {
    enum Content {
        case loading
        case chips([(member: HomeMember, status: CellStatus)])
    }

    let content: Content
    var calendar: Calendar = .current

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                switch content {
                case .loading:
                    ForEach(0..<4, id: \.self) { _ in
                        Capsule().fill(Color.skeleton).frame(width: 92, height: 38)
                    }
                    .accessibilityHidden(true)
                case .chips(let chips):
                    ForEach(chips, id: \.member.id) { chip($0.member, $0.status) }
                }
            }
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(minHeight: 44)
        .accessibilityIdentifier("chips")
    }

    private func chip(_ m: HomeMember, _ status: CellStatus) -> some View {
        let word = status.word(calendar: calendar)
        return HStack(spacing: 8) {
            FriendAvatar(member: m, size: 28, style: .badge)
            VStack(alignment: .leading, spacing: 0) {
                Text(m.name).textStyle(.label).foregroundStyle(DesignTokens.Colors.text)
                HStack(spacing: 4) {
                    StatusDot(color: status.dotColor)
                    Text(word).textStyle(.caption).foregroundStyle(DesignTokens.Colors.text)
                }
            }
            .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(Capsule().fill(DesignTokens.Colors.surface))
        .overlay(Capsule().stroke(DesignTokens.Colors.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(m.name), \(word)")
    }
}

#Preview("Chips, populated") {
    let model = HomeModel(fixture: FixtureData.make(.populated))
    FriendStatusChips(content: .chips(model.chips ?? []))
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Chips, 0-count cell selected") {
    let model = HomeModel(fixture: FixtureData.make(.zeroOverlap))
    if let cell = model.visibleWeek?.cells.first(where: \.isEnabled) { model.select(cell.id) }
    return FriendStatusChips(content: .chips(model.chips ?? []))
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Chips, loading") {
    FriendStatusChips(content: .loading).padding(20).background(DesignTokens.Colors.background)
}
