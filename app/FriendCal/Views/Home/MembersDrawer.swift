import SwiftUI
import FriendCalCore

/// Every group member by recent activity (D36), opened from the "+N" face. Statuses come from the
/// selected cell's roster (X2); with nothing selected, rows show no status (X11).
struct MembersDrawer: View {
    let groupName: String
    let members: [HomeMember]
    /// nil = no selected cell.
    let roster: [UUID: CellStatus]?
    var calendar: Calendar = .current
    var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(groupName) · \(members.count)")
                    .textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                    .accessibilityAddTraits(.isHeader)
                if roster == nil && !isLoading {
                    Text("Pick a time to see who's free")
                        .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, DesignTokens.Spacing.sm)

            ScrollView {
                // Eager: at most a group's worth of rows, and UI tests count them all (D36).
                VStack(spacing: 0) {
                    if isLoading {
                        ForEach(0..<6, id: \.self) { _ in skeletonRow }
                    } else {
                        ForEach(members) { row($0) }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .background(DesignTokens.Colors.surface)
        .accessibilityIdentifier("membersDrawer")
    }

    private func row(_ m: HomeMember) -> some View {
        let status = roster?[m.id]
        return HStack(spacing: 12) {
            FriendAvatar(member: m, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if m.isOnline {
                        StatusDot(color: DesignTokens.Colors.accent)
                            .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.surface, lineWidth: 1.5))
                    }
                }
            Text(m.name).textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
            Spacer(minLength: DesignTokens.Spacing.sm)
            if let status {
                HStack(spacing: 4) {
                    StatusDot(color: status.dotColor)
                    Text(status.word(calendar: calendar)).textStyle(.caption).foregroundStyle(DesignTokens.Colors.text)
                }
            }
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.Colors.border).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([m.name, status?.word(calendar: calendar), m.isOnline ? "online" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("drawer.row")
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            SwiftUI.Circle().fill(Color.skeleton).frame(width: 40, height: 40)
            Capsule().fill(Color.skeleton).frame(width: 120, height: 12)
            Spacer()
        }
        .frame(minHeight: 56)
        .accessibilityHidden(true)
    }
}

#Preview("Drawer, selected cell") {
    let model = HomeModel(fixture: FixtureData.make(.populated))
    MembersDrawer(groupName: model.groupName, members: model.members, roster: model.selectedCell?.roster)
}

#Preview("Drawer, no selection") {
    MembersDrawer(groupName: "Brunch crew", members: FixtureData.members, roster: nil)
}

#Preview("Drawer, loading") {
    MembersDrawer(groupName: "Brunch crew", members: [], roster: nil, isLoading: true)
}
