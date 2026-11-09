import SwiftUI
import FriendCalCore

/// Initials on a fixed earth color (D28), stable per member via FNV-1a (T12).
struct FriendAvatar: View {
    let member: HomeMember
    var size: CGFloat = 40
    var style: DesignTokens.TextStyle = .label

    var body: some View {
        if member.name == User.deletedDisplayName {
            DepartedAvatar(size: size)
        } else {
            face
        }
    }

    private var face: some View {
        SwiftUI.Circle()
            .fill(DesignTokens.FacePalette.color(for: member.id))
            .frame(width: size, height: size)
            .overlay(Text(member.initials).textStyle(style).foregroundStyle(DesignTokens.Colors.text).minimumScaleFactor(0.6).lineLimit(1).padding(2)
                // The circle is fixed-size, so its initials stop growing at the default size; the
                // name beside every avatar carries the scalable text.
                .dynamicTypeSize(...DynamicTypeSize.large))
            .accessibilityHidden(true)
    }
}

/// A friend who deleted their account (design 5.3A): a neutral person glyph in `textMuted` on
/// `surface2` with a hairline border, spoken as "A friend". The initials and face color of a
/// tombstone row would be meaningless, so none is drawn.
struct DepartedAvatar: View {
    var size: CGFloat = 40
    var body: some View {
        SwiftUI.Circle()
            .fill(DesignTokens.Colors.surface2)
            .frame(width: size, height: size)
            .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.border, lineWidth: 1))
            .overlay(Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(DesignTokens.Colors.textMuted))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("A friend")
    }
}

extension CellStatus {
    /// Chip and drawer word (D35): free / maybe / after N / busy.
    func word(calendar: Calendar) -> String {
        switch self {
        case .free: return "free"
        case .maybe: return "maybe"
        case .busy: return "busy"
        case .after(let date):
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = calendar.component(.minute, from: date) == 0 ? "h" : "h:mm"
            return "after \(f.string(from: date))"
        }
    }

    /// Status dot (D25): the word stays in text color; the dot carries the hue.
    var dotColor: Color {
        switch self {
        case .free: return DesignTokens.Colors.success
        case .maybe: return DesignTokens.Colors.warning
        case .after: return DesignTokens.Colors.accent
        case .busy: return DesignTokens.Colors.textMuted
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { SwiftUI.Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true) }
}

#Preview("Avatars") {
    HStack {
        ForEach(FixtureData.members.prefix(6)) { FriendAvatar(member: $0) }
    }
    .padding()
    .background(DesignTokens.Colors.background)
}
