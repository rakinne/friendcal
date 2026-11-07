import SwiftUI
import FriendCalCore

/// Who is in or out for the selected cell (D22, D35), from its roster (X2). More than 4 scroll
/// horizontally, with the last chip clipped at the edge (D19). HomeView hides the row when nothing
/// is selected. Once a plan is locked the chips read "in" for attendees (issue #5 design 2.2A).
struct FriendStatusChips: View {
    enum Content {
        case loading
        case chips([(member: HomeMember, status: CellStatus)])
        case attendees([(member: HomeMember, isIn: Bool)])
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
                    ForEach(chips, id: \.member.id) { chip($0.member, word: $0.status.word(calendar: calendar), dot: $0.status.dotColor) }
                case .attendees(let rows):
                    ForEach(rows, id: \.member.id) { chip($0.member, word: $0.isIn ? "in" : "out", dot: $0.isIn ? DesignTokens.Colors.primary : DesignTokens.Colors.textMuted) }
                }
            }
            .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .frame(minHeight: 44)
        .accessibilityIdentifier("chips")
    }

    private func chip(_ m: HomeMember, word: String, dot: Color) -> some View {
        HStack(spacing: 8) {
            FriendAvatar(member: m, size: 28, style: .badge)
            VStack(alignment: .leading, spacing: 0) {
                Text(m.name).textStyle(.label).foregroundStyle(DesignTokens.Colors.text)
                HStack(spacing: 4) {
                    StatusDot(color: dot)
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
    let model = ProposalSession(fixture: FixtureData.make(.populated))
    FriendStatusChips(content: .chips(model.chips ?? []))
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Chips, 0-count cell selected") {
    let model = ProposalSession(fixture: FixtureData.make(.zeroOverlap))
    if let cell = model.visibleWeek?.cells.first(where: \.isEnabled) { model.select(cell.id) }
    return FriendStatusChips(content: .chips(model.chips ?? []))
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Chips, locked") {
    let model = ProposalSession(fixture: FixtureData.make(.lockedPlan))
    FriendStatusChips(content: .attendees(model.attendeeChips ?? []))
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Chips, loading") {
    FriendStatusChips(content: .loading).padding(20).background(DesignTokens.Colors.background)
}
