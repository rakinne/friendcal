import SwiftUI
import FriendCalCore

/// The myFaves wheel (D28, D36). 240pt square, orbit radius 92, 40pt faces at 36° steps from
/// 12 o'clock. One coral arc pulses toward the active friend: it is the app's only endlessly repeating
/// animation (D23, AC5) and stops under Reduce Motion. Text stops growing at xxxLarge, like the
/// heatmap (D31 amendment): faces, orbit and centre share fixed geometry, so larger sizes would
/// push the centre text into the faces.
struct FriendsWheel: View {
    enum Content {
        case loading
        case members(faces: [HomeMember], overflow: Int, onlineCount: Int)
    }

    let content: Content
    /// VoiceOver status for a face ("free", "online").
    var status: (HomeMember) -> String = { $0.isOnline ? "online" : "away" }
    var onMore: () -> Void = {}
    var onInvite: () -> Void = {}

    static let size: CGFloat = 240
    static let orbit: CGFloat = 92
    static let face: CGFloat = 40

    var body: some View {
        ZStack {
            switch content {
            case .loading: loading
            case .members(let faces, _, _) where faces.isEmpty: empty
            case .members(let faces, let overflow, let online): populated(faces: faces, overflow: overflow, online: online)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    // MARK: States

    private var loading: some View {
        ZStack {
            SwiftUI.Circle().stroke(Color.skeleton, lineWidth: 1).frame(width: Self.orbit * 2, height: Self.orbit * 2)
            ForEach(0..<10, id: \.self) { i in
                SwiftUI.Circle().fill(Color.skeleton).frame(width: Self.face, height: Self.face)
                    .position(Self.point(angle: Double(i) * 36))
            }
            VStack(spacing: 6) {
                Capsule().fill(Color.skeleton).frame(width: 96, height: 22)
                Capsule().fill(Color.skeleton).frame(width: 64, height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading friends")
    }

    private var empty: some View {
        ZStack {
            SwiftUI.Circle()
                .stroke(DesignTokens.Colors.border, style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                .frame(width: Self.orbit * 2, height: Self.orbit * 2)
            VStack(spacing: DesignTokens.Spacing.sm) {
                Text("Add your first fave")
                    .textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                    .multilineTextAlignment(.center)
                Button(action: onInvite) {
                    Text("Invite").textStyle(.label).foregroundStyle(DesignTokens.Colors.onPrimary)
                        .padding(.horizontal, DesignTokens.Spacing.md).frame(minHeight: 44)
                        .background(Capsule().fill(DesignTokens.Colors.accentHover))
                }
                .accessibilityIdentifier("wheel.invite")
            }
            .frame(width: Self.orbit * 2 - 24)
        }
    }

    private func populated(faces: [HomeMember], overflow: Int, online: Int) -> some View {
        let slots = faces.count + (overflow > 0 ? 1 : 0)
        let step = overflow > 0 ? 36 : 360 / Double(max(slots, 1))
        let angles = (0..<slots).map { Double($0) * step }
        let gap = Self.faceHalfAngle + 2
        return ZStack {
            SwiftUI.Circle()
                .stroke(DesignTokens.Colors.border, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                .frame(width: Self.orbit * 2, height: Self.orbit * 2)
            // Neighbor arcs: the group drawn as connected (none for 1-3 friends, D19).
            if slots >= 4 {
                ForEach(0..<slots, id: \.self) { i in
                    let next = i + 1 < slots ? angles[i + 1] : 360
                    ArcShape(from: angles[i] + gap, to: next - gap)
                        .stroke(DesignTokens.Colors.border, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
            }
            if let activeIndex = faces.firstIndex(where: \.isActive), slots >= 4 {
                ActiveArc(endAngle: angles[activeIndex] - gap)
            }
            VStack(spacing: 2) {
                Text("myFaves").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                Text("\(online) online-ish").textStyle(.caption).foregroundStyle(DesignTokens.Colors.accentHover)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: Self.orbit * 2 - Self.face - 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("wheel.center")

            ForEach(Array(faces.enumerated()), id: \.element.id) { i, member in
                WheelFace(member: member, status: status(member))
                    .position(Self.point(angle: angles[i]))
            }
            if overflow > 0 {
                Button(action: onMore) {
                    SwiftUI.Circle().fill(DesignTokens.FacePalette.sand)
                        .frame(width: Self.face, height: Self.face)
                        .overlay(Text("+\(overflow)").textStyle(.label).foregroundStyle(DesignTokens.Colors.text).minimumScaleFactor(0.6).lineLimit(1))
                        .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.background, lineWidth: 1.5))
                        .frame(width: 44, height: 44)
                        .contentShape(SwiftUI.Circle())
                }
                .buttonStyle(.plain)
                .position(Self.point(angle: angles[slots - 1]))
                .accessibilityLabel("+\(overflow) more friends")
                .accessibilityIdentifier("wheel.more")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("myFaves wheel")
    }

    // MARK: Geometry

    /// Half the angle a face covers on the orbit.
    static let faceHalfAngle = asin(Double(face / 2) / Double(orbit)) * 180 / .pi

    /// `angle` in degrees clockwise from 12 o'clock.
    static func point(angle: Double, radius: CGFloat = orbit) -> CGPoint {
        let r = angle * .pi / 180
        return CGPoint(x: size / 2 + radius * CGFloat(sin(r)), y: size / 2 - radius * CGFloat(cos(r)))
    }
}

/// A face on the orbit: initials, online dot at 4 o'clock, coral ring for the active friend.
private struct WheelFace: View {
    let member: HomeMember
    let status: String

    var body: some View {
        FriendAvatar(member: member, size: FriendsWheel.face)
            .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.background, lineWidth: 1.5))
            .overlay {
                if member.isActive {
                    SwiftUI.Circle().stroke(DesignTokens.Colors.primary, lineWidth: 2).padding(-2)
                }
            }
            .overlay {
                if member.isOnline {
                    // 4 o'clock = 120° clockwise from 12 on the face's edge.
                    StatusDot(color: DesignTokens.Colors.accent)
                        .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.surface, lineWidth: 1.5))
                        .offset(x: 20 * sin(2 * .pi / 3), y: -20 * cos(2 * .pi / 3))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(member.name), \(status)")
            .accessibilityIdentifier("wheel.face")
    }
}

/// An arc on the wheel's orbit, angles in degrees clockwise from 12 o'clock.
private struct ArcShape: Shape {
    var from: Double
    var to: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard to > from else { return p }
        let steps = max(Int((to - from) / 3), 2)
        for s in 0...steps {
            let pt = FriendsWheel.point(angle: from + (to - from) * Double(s) / Double(steps))
            let shifted = CGPoint(x: pt.x - (FriendsWheel.size - rect.width) / 2, y: pt.y - (FriendsWheel.size - rect.height) / 2)
            s == 0 ? p.move(to: shifted) : p.addLine(to: shifted)
        }
        return p
    }
}

/// 3pt coral, 40° ending at the active friend (D28). Pulses with a spring (response 0.5,
/// damping 0.82); static under Reduce Motion (D23).
private struct ActiveArc: View {
    let endAngle: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        ArcShape(from: endAngle - 40, to: endAngle)
            .stroke(DesignTokens.Colors.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .opacity(dim ? 0.45 : 1)
            .accessibilityHidden(true)
            .onAppear { startPulse() }
            .onChange(of: reduceMotion) { startPulse() }
    }

    private func startPulse() {
        guard !reduceMotion else {
            withAnimation(nil) { dim = false }
            return
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82).repeatForever(autoreverses: true)) { dim = true }
    }
}

extension Color {
    /// Skeleton fill for loading states (D19: drawn skeletons, not `.redacted`).
    static let skeleton = DesignTokens.Colors.border.opacity(0.7)
}

#Preview("Wheel, 15 members") {
    let model = HomeModel(fixture: FixtureData.make(.populated))
    FriendsWheel(content: .members(faces: model.wheel.faces, overflow: model.wheel.overflow, onlineCount: model.onlineCount))
        .background(DesignTokens.Colors.background)
}

#Preview("Wheel, 10 members") {
    let ten = Array(FixtureData.members.prefix(10))
    FriendsWheel(content: .members(faces: ten, overflow: 0, onlineCount: 10))
        .background(DesignTokens.Colors.background)
}

#Preview("Wheel, 3 members") {
    FriendsWheel(content: .members(faces: Array(FixtureData.members.prefix(3)), overflow: 0, onlineCount: 3))
        .background(DesignTokens.Colors.background)
}

#Preview("Wheel, empty") {
    FriendsWheel(content: .members(faces: [], overflow: 0, onlineCount: 0))
        .background(DesignTokens.Colors.background)
}

#Preview("Wheel, loading") {
    FriendsWheel(content: .loading)
        .background(DesignTokens.Colors.background)
}
