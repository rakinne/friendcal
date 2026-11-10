import SwiftUI
import FriendCalCore

extension Buddy {
    /// The face component still speaks `HomeMember`; initials and the stable earth color come from it.
    var face: HomeMember { HomeMember(id: id, name: name, isOnline: isOnline, isActive: false) }
}

extension Presence {
    var scene: SceneStyle {
        switch self {
        case .status(let s): .status(s.kind)
        case .busy: .busy
        case .quiet: .quiet
        }
    }
}

/// The status glyph pinned to a face: a slightly tilted ivory tile, so it reads as a sticker. A
/// distinct silhouette per kind plus the word on the plate, never hue alone (D25). Busy is a grey
/// dash with no glyph and no reason; "you, nothing set" is a coral plus that asks for a status.
struct StatusSticker: View {
    let presence: Presence
    var isYou = false
    var size: CGFloat = 30

    var body: some View {
        if let glyph {
            Image(systemName: glyph.name)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(glyph.color)
                .symbolEffect(.bounce, value: presence.word)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.3).fill(DesignTokens.Colors.surface))
                .overlay(RoundedRectangle(cornerRadius: size * 0.3).stroke(DesignTokens.Colors.border, lineWidth: 1))
                .shadow(color: DesignTokens.Colors.shadow.opacity(0.35), radius: 3, y: 2)
                .rotationEffect(.degrees(-7))
                .accessibilityHidden(true)
        }
    }

    private var glyph: (name: String, color: Color)? {
        switch presence {
        case .status(let s): (s.kind.symbolName, DesignTokens.Colors.accentHover)
        case .busy: (StatusKind.busySymbolName, DesignTokens.Colors.textMuted)
        case .quiet: isYou ? ("plus", DesignTokens.Colors.primary) : nil
        }
    }
}

/// A tall buddy-list row over its status scene (variant D). Avatar and sticker sit on the scene; the
/// name, word, time and away message sit on an opaque ivory plate (inner radius 12 inside the 20pt
/// row with an 8pt gap, DESIGN.md), so text never depends on the art behind it. Busy rows are flat
/// grey. The whole row is one VoiceOver element carrying one spoken sentence.
struct GroupRow: View {
    let buddy: Buddy
    let presence: Presence
    let text: RowText
    var isYou = false
    /// Builder mode: nil = not picking, else whether this friend is ticked.
    var ticked: Bool?
    var animates = true
    /// "52 min left" while your poke to this friend is still out.
    var poked: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isBusy: Bool { presence == .busy }

    var body: some View {
        HStack(spacing: 0) {
            face
                .frame(width: 88)
            Spacer(minLength: 0)
            // The plate takes about 56% of the width so the scene stays readable beside it.
            plate
                .containerRelativeFrame(.horizontal) { width, _ in width * 0.56 }
                .padding(.vertical, 8)
                .padding(.trailing, 8)
        }
        .frame(minHeight: 100)
        .background { SceneArt(style: presence.scene, anchor: 0.24, animates: animates) }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .shadow(color: DesignTokens.Colors.shadow.opacity(0.12), radius: 12, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken)
        .accessibilityValue(ticked.map { $0 ? "selected" : "not selected" } ?? "")
        .accessibilityAddTraits(ticked == true ? .isSelected : [])
        .accessibilityIdentifier("groups.row")
    }

    private var face: some View {
        ZStack(alignment: .bottomTrailing) {
            FriendAvatar(member: buddy.face, size: 56, style: .title)
                .saturation(isBusy ? 0 : 1)
                .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.surface, lineWidth: 2.5))
                .padding(.trailing, 6)
                .padding(.bottom, 4)
            StatusSticker(presence: presence, isYou: isYou)
                .offset(x: 2, y: 4)
        }
        .overlay(alignment: .topLeading) {
            if let ticked { tick(ticked).offset(x: -4, y: -4) }
        }
    }

    private func tick(_ on: Bool) -> some View {
        SwiftUI.Circle()
            .fill(on ? DesignTokens.Colors.primary : DesignTokens.Colors.surface)
            .frame(width: 26, height: 26)
            .overlay(SwiftUI.Circle().stroke(on ? Color.clear : DesignTokens.Colors.textMuted, lineWidth: 1.5))
            .overlay(Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(DesignTokens.Colors.onPrimary).opacity(on ? 1 : 0))
            .animation(.snappy(duration: 0.18), value: on)
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isYou ? "You" : buddy.name)
                .textStyle(.rowName)
                .foregroundStyle(DesignTokens.Colors.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 6) {
                Text(presence.word.uppercased())
                    .textStyle(.badge)
                    .tracking(0.8)
                    .foregroundStyle(isBusy || presence == .quiet ? DesignTokens.Colors.textMuted : DesignTokens.Colors.accentHover)
                if let time = text.time {
                    Text(time).textStyle(.mono).foregroundStyle(DesignTokens.Colors.text).lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            if let message = text.message {
                Text(message)
                    .textStyle(.body)
                    .italic()
                    .foregroundStyle(DesignTokens.Colors.text)
                    .lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
            }
            if let poked {
                // A coral hand plus the words in text color: coral text on ivory is under 4.5:1.
                HStack(spacing: 4) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DesignTokens.Colors.primary)
                    Text("poked · \(poked)").textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).fill(isBusy ? DesignTokens.Colors.surface2 : DesignTokens.Colors.surface))
    }
}

#Preview("Rows") {
    let now = Date()
    let people: [(String, Presence)] = [
        ("Maya", .status(FriendStatus(kind: .work, message: "closing shift, send snacks", since: now.addingTimeInterval(-3600), until: now.addingTimeInterval(10_000)))),
        ("Leo", .status(FriendStatus(kind: .movies, message: "dune part three, no spoilers", since: now.addingTimeInterval(-2000), until: now.addingTimeInterval(5400)))),
        ("Nina", .status(FriendStatus(kind: .concert, message: "khruangbin row 4", since: now.addingTimeInterval(-2400)))),
        ("Arlo", .status(FriendStatus(kind: .free, message: "down for tacos, anyone", since: now.addingTimeInterval(-600)))),
        ("Mika", .busy),
        ("Rosa", .quiet),
    ]
    return ScrollView {
        VStack(spacing: 10) {
            ForEach(people, id: \.0) { name, presence in
                GroupRow(buddy: Buddy(id: UUID(), name: name), presence: presence,
                         text: presence.rowText(name: name, now: now))
            }
        }
        .padding(20)
    }
    .background(DesignTokens.Colors.background)
}
