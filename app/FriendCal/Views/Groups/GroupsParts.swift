import SwiftUI
import FriendCalCore

/// The one live line at the top (variant D). A prompt to act built from overlap and what is ending
/// soon, not a sign-on log. The dot beats once whenever the line changes, like Home's LIVE dot.
struct MomentsCard: View {
    let moment: Moment
    var onAction: (Moment.Action) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(DesignTokens.Colors.accent)
                .symbolEffect(.bounce, options: .nonRepeating, value: moment.text)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(moment.text).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = moment.detail {
                    Text(detail).textStyle(.body).italic().foregroundStyle(DesignTokens.Colors.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = moment.action {
                Button { onAction(action) } label: {
                    Text(action.label).textStyle(.label).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(DesignTokens.Colors.onPrimary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(DesignTokens.Colors.primary))
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("groups.moment.action")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .animation(.snappy, value: moment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("groups.moment")
    }
}

/// A folder's header: a rotating chevron, the name, "(4/5 online)". Tapping folds the rows away.
struct FolderHeader: View {
    let folder: GroupsFolder
    let isExpanded: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DesignTokens.Colors.accentHover)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(folder.title).textStyle(.rowName).foregroundStyle(DesignTokens.Colors.text).lineLimit(1)
                if !folder.members.isEmpty {
                    Text("(\(folder.onlineCount)/\(folder.members.count) online)").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                }
                if folder.isAutomatic {
                    Text("AUTO").textStyle(.badge).tracking(0.8).foregroundStyle(DesignTokens.Colors.accentHover)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .overlay(Capsule().stroke(DesignTokens.Colors.accentHover, lineWidth: 1))
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isExpanded)
        .accessibilityLabel(folder.members.isEmpty ? folder.title : "\(folder.title), \(folder.onlineCount) of \(folder.members.count) online")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("groups.folder")
    }
}

/// The zero-crew prompt (and the way into the builder): coral-edged ivory, one tap.
struct StartCrewCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill").font(.system(size: 20)).foregroundStyle(DesignTokens.Colors.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a crew").textStyle(.rowName).foregroundStyle(DesignTokens.Colors.text)
                    Text("Pick friends and plan something together").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Start").textStyle(.label).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.Colors.primary))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).stroke(DesignTokens.Colors.primary, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Start a crew. Pick friends and plan something together")
        .accessibilityIdentifier("groups.startCrew")
    }
}

/// A dashed open seat: an invitation, not an empty row. It is an honest stub until invite links exist.
struct InviteSeatCard: View {
    var title = "Open seat"
    var subtitle = "Invite a friend"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.plus").font(.system(size: 20)).foregroundStyle(DesignTokens.Colors.accentHover)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                    Text(subtitle).textStyle(.body).foregroundStyle(DesignTokens.Colors.accentHover)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous)
                .stroke(DesignTokens.Colors.accentHover.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityIdentifier("groups.invite")
    }
}

/// The nine stickers peeking under your row while nothing is set. One tap opens the studio on that scene.
struct StickerTray: View {
    var pick: (StatusKind) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(StatusKind.allCases) { kind in
                    Button { pick(kind) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: kind.symbolName).font(.system(size: 14, weight: .bold)).accessibilityHidden(true)
                            Text(kind.word).textStyle(.label)
                        }
                        .foregroundStyle(DesignTokens.Colors.accentHover)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(DesignTokens.Colors.surface))
                        .overlay(Capsule().stroke(DesignTokens.Colors.border, lineWidth: 1))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Set status: \(kind.word)")
                    .accessibilityIdentifier("groups.tray.\(kind.word)")
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .accessibilityIdentifier("groups.tray")
    }
}
