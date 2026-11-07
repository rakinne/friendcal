import SwiftUI
import FriendCalCore

/// Coral Cabinet Grotesk wordmark (D27: 28pt ExtraBold, -0.01em).
struct BrandWordmark: View {
    var body: some View {
        Text("FriendCal")
            .textStyle(.wordmark)
            .foregroundStyle(DesignTokens.Colors.primary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Static group label (D20): avatar stack + name, no chevron, not a button. Switching groups is
/// out of scope. On the in-memory store it carries the DEMO badge as a trailing sibling (issue #5
/// D7, D10: inside the header row, never a new row, so the AC2 one-screen layout holds).
struct GroupPickerPill: View {
    let name: String
    let members: [HomeMember]
    var isLoading = false
    var isDemo = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -4) {
                ForEach(members.prefix(3)) { m in
                    FriendAvatar(member: m, size: 22, style: .badge)
                        .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.surface, lineWidth: 1.5))
                }
            }
            Text(name).textStyle(.label).foregroundStyle(DesignTokens.Colors.text).lineLimit(1)
            if isDemo { DemoBadge() }
        }
        .padding(.leading, members.isEmpty ? 10 : 6)
        .padding(.trailing, isDemo ? 6 : 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(DesignTokens.Colors.surface))
        .overlay(Capsule().stroke(DesignTokens.Colors.border, lineWidth: 1))
        .opacity(isLoading ? 0 : 1)
        .overlay { if isLoading { Capsule().fill(Color.skeleton).frame(width: 110, height: 28) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoading ? "Loading group" : "Group, \(name)" + (isDemo ? ", demo data, not synced" : ""))
        .accessibilityIdentifier("home.groupPill")
    }
}

/// "DEMO": a badge-style capsule, `warning` outline, 20pt tall (design Pass 5 mechanics). The word is
/// in `text`, not `warning`: amber text on ivory is 2.05:1 (ContrastTests), so only the outline carries the hue.
struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .textStyle(.badge)
            .tracking(0.4)
            .foregroundStyle(DesignTokens.Colors.text)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .overlay(Capsule().stroke(DesignTokens.Colors.warning, lineWidth: 1))
            .accessibilityIdentifier("home.demo")
    }
}

#Preview("Header, populated") {
    HStack { BrandWordmark(); Spacer(); GroupPickerPill(name: "Brunch crew", members: FixtureData.members, isDemo: true) }
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Header, empty") {
    HStack { BrandWordmark(); Spacer(); GroupPickerPill(name: "Brunch crew", members: []) }
        .padding(20).background(DesignTokens.Colors.background)
}

#Preview("Header, loading") {
    HStack { BrandWordmark(); Spacer(); GroupPickerPill(name: "Brunch crew", members: [], isLoading: true) }
        .padding(20).background(DesignTokens.Colors.background)
}
