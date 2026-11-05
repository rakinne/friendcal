import SwiftUI

/// T-Mobile myFaves-inspired rotary of 5-10 friends. Nostalgic, tactile, shows network liveness.
/// Tap face → profile sheet with sanitized upcoming Busy, open Tap-Ins, Tag Along events.
/// Kinetic Warmth: ember pulse only on active arcs, spring settle, surrounding chrome calm.
struct MyFavesWheelView: View {
    var friends: [User]
    var onSelect: (User) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let radius: CGFloat = min(geo.size.width, geo.size.height) * 0.35
            ZStack {
                // Orbit guide — hairline dashed, warm border
                SwiftUI.Circle()
                    .stroke(DesignTokens.Colors.border, style: StrokeStyle(lineWidth: 1, dash: [6,6]))
                    .frame(width: radius*2, height: radius*2)
                    .position(x: geo.size.width/2, y: geo.size.height/2)
                ForEach(Array(friends.enumerated()), id: \.element.id) { idx, user in
                    let angle = Double(idx) / Double(max(friends.count, 1)) * 2 * .pi - .pi/2
                    FriendFaceView(user: user)
                        .position(
                            x: geo.size.width/2 + cos(angle) * radius,
                            y: geo.size.height/2 + sin(angle) * radius
                        )
                        .onTapGesture { onSelect(user) }
                }
                // Center: FriendCal ghost — delights / re-engages (haunts if quiet, celebrates convergence)
                GhostView()
                    .frame(width: 64, height: 64)
            }
        }
        .frame(height: 280)
        .accessibilityLabel("My Friends wheel")
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78), value: friends.count)
    }
}

struct FriendFaceView: View {
    let user: User
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var pulsing = false
    var body: some View {
        AsyncImage(url: user.avatarURL) { phase in
            if let img = phase.image { img.resizable().scaledToFill() } else { SwiftUI.Circle().fill(DesignTokens.Colors.border.opacity(0.35)) }
        }
        .frame(width: 56, height: 56)
        .clipShape(SwiftUI.Circle())
        .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.accent, lineWidth: 2))
        .overlay(SwiftUI.Circle().stroke(DesignTokens.Colors.primary.opacity(pulsing ? 0.5 : 0), lineWidth: 4).scaleEffect(pulsing ? 1.12 : 0.95))
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulsing)
        .onAppear { if !reduceMotion { pulsing = true } }
        .accessibilityAddTraits(.isButton)
    }
}

struct GhostView: View {
    var body: some View {
        Text("👻")
            .font(.system(size: 36))
            .accessibilityLabel("FriendCal ghost")
    }
}
