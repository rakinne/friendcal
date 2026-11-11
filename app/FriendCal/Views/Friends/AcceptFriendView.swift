import SwiftUI
import FriendCalCore

/// Accept (spec 4.3): a full-screen cover the shell presents when a friend link is pending. Opening
/// the link calls nothing but preview; the connection is made only when Connect is tapped.
///
///     wordmark
///     (you) ~~~~ arc ~~~~ (Sam)
///     Sam wants to connect
///     You and Sam will see each other's names and when you're busy. Plan details stay private unless you share them.
///     [ Connect with Sam ]
///               Not now
///
/// The name is the one the server returned, never the hint in the URL.
struct AcceptFriendView: View {
    let flow: FriendAcceptFlow
    let me: HomeMember
    /// Connected: the shell takes over (Groups, highlight, haptic).
    var onConnected: (Friend) -> Void
    /// "Not now": clears the pending link.
    var onNotNow: () -> Void
    /// A terminal state was acknowledged: "OK", or after "Share it" / "Open Groups".
    var onAnswered: (Followup) -> Void

    enum Followup { case ok, shareLink, openGroups }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.lg) {
                BrandWordmark().frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                Spacer(minLength: 12)
                content
            }
            .padding(.horizontal, 24).padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .accessibilityIdentifier("accept")
        .task { await flow.check() }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.phase {
        case .checking:
            VStack(spacing: DesignTokens.Spacing.md) {
                pair(them: nil)
                Capsule().fill(Color.skeleton).frame(width: 220, height: 30)
                Capsule().fill(Color.skeleton).frame(width: 280, height: 14)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Checking link")
            .accessibilityIdentifier("accept.checking")

        case .checkFailed(let error):
            VStack(spacing: DesignTokens.Spacing.md) {
                pair(them: nil)
                InlineError(error: error, onRetry: { Task { await flow.check() } })
                notNow
            }

        case .ready(let friend), .connecting(let friend), .connectFailed(let friend, _):
            VStack(spacing: DesignTokens.Spacing.md) {
                pair(them: friend)
                Text("\(friend.name) wants to connect").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                    .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("accept.headline")
                Text("You and \(friend.name) will see each other's names and when you're busy. Plan details stay private unless you share them.")
                    .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("accept.body")
                connectButton(friend)
                if case .connectFailed(_, let error) = flow.phase {
                    InlineError(error: error, onRetry: { connect() })
                }
                notNow
            }

        case .dead:
            terminal(title: "This link doesn't work anymore.", button: "OK", id: "accept.dead") { onAnswered(.ok) }

        case .own:
            terminal(title: "This is your link", button: "Share it", id: "accept.own") { onAnswered(.shareLink) }

        case .already(let friend):
            terminal(title: "You and \(friend.name) are already connected", button: "Open Groups", id: "accept.already") { onAnswered(.openGroups) }
        }
    }

    // MARK: Pieces

    private func pair(them: Friend?) -> some View {
        HStack(spacing: 0) {
            FriendAvatar(member: me, size: 76, style: .display)
            ZStack {
                ConnectArc().stroke(DesignTokens.Colors.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                    .frame(height: 36)
            }
            .frame(width: 72)
            if let them {
                FriendAvatar(member: HomeMember(id: them.id, name: them.name, isOnline: true, isActive: false), size: 76, style: .display)
            } else {
                SwiftUI.Circle().fill(Color.skeleton).frame(width: 76, height: 76)
            }
        }
        .accessibilityHidden(true)
    }

    private func connectButton(_ friend: Friend) -> some View {
        let busy: Bool = { if case .connecting = flow.phase { return true }; return false }()
        return Button(action: connect) {
            PrimaryPill(title: busy ? "Connecting" : "Connect with \(friend.name)", isBusy: busy)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier("accept.connect")
    }

    private var notNow: some View {
        let busy: Bool = { if case .connecting = flow.phase { return true }; return false }()
        return Button(action: onNotNow) {
            Text("Not now").textStyle(.title).foregroundStyle(DesignTokens.Colors.textMuted)
                .frame(minWidth: 88, minHeight: 44).contentShape(Rectangle())
        }
        .disabled(busy)
        .accessibilityIdentifier("accept.notNow")
    }

    private func terminal(title: String, button: String, id: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Text(title).textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("\(id).title")
            Button(action: action) { PrimaryPill(title: button) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(id).button")
        }
        .padding(.top, 32)
    }

    private func connect() {
        Task {
            if let friend = await flow.connect() { onConnected(friend) }
        }
    }
}

/// The arc joining the two avatars: a shallow curve from the left edge to the right.
private struct ConnectArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.4))
        return path
    }
}
