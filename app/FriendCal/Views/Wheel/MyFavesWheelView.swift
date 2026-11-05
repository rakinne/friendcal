import SwiftUI

/// T-Mobile myFaves-inspired rotary of 5-10 friends. Nostalgic, tactile, shows network liveness.
/// Tap face → profile sheet with sanitized upcoming Busy, open Tap-Ins, Tag Along events.
struct MyFavesWheelView: View {
    var friends: [User]
    var onSelect: (User) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let radius: CGFloat = min(geo.size.width, geo.size.height) * 0.35
            ZStack {
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
    }
}

struct FriendFaceView: View {
    let user: User
    var body: some View {
        AsyncImage(url: user.avatarURL) { phase in
            if let img = phase.image { img.resizable().scaledToFill() } else { Circle().fill(Color.gray.opacity(0.2)) }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.yellow, lineWidth: 2)) // unread pulse tint
    }
}

struct GhostView: View {
    var body: some View {
        Text("👻")
            .font(.system(size: 36))
            .accessibilityLabel("FriendCal ghost")
    }
}
