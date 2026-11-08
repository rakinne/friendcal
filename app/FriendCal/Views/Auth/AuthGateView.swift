import FriendCalCore
import SwiftUI

/// Gate + name prompt per 1.3A / 1E / 2K / 3A / 2I / 2J
struct AuthGateView: View {
    @ObservedObject var auth: AuthGateModel
    var pendingTitle: String?
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.Colors.primary)
                .accessibilityHidden(true)
            Text("Welcome to FriendCal").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)
            if let pendingTitle {
                Text("You were invited to \(pendingTitle)").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("auth.pendingLine")
            } else {
                Text("Plan together, stay in sync").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            VStack(spacing: DesignTokens.Spacing.sm) {
                TextField("Your name", text: $name)
                    .textStyle(.body)
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(DesignTokens.Colors.border, lineWidth: 1))
                    .focused($focused)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("auth.nameField")
                Text("Shown to friends on your invites").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            PrimaryPill(title: "Continue", isBusy: auth.state == .signingIn)
                .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || auth.state == .signingIn ? 0.5 : 1)
                .onTapGesture {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, auth.state != .signingIn else { return }
                    Task { await auth.signIn(displayName: trimmed) }
                }
                .accessibilityIdentifier("auth.continue")
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if case .failed(let err) = auth.state {
                InlineError(error: err) { Task { await auth.signIn(displayName: name) } }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
    }
}

@MainActor
final class AuthGateModel: ObservableObject {
    @Published var state: AuthState = .signedOut
    let store: ProposalStore
    private var task: Task<Void, Never>?

    init(store: ProposalStore) {
        self.store = store
        self.state = store.authState
        task = Task { [weak self] in
            guard let self else { return }
            for await s in store.authChanges {
                self.state = s
            }
        }
    }

    func signIn(displayName: String) async {
        do {
            _ = try await store.signIn(displayName: displayName)
            // cache name per account-scoped key
            if let id = store.currentUserID {
                UserDefaults.standard.set(displayName, forKey: "FriendCalDisplayName.\(id.uuidString)")
            }
        } catch {
            // state already set to .failed by store
        }
    }
}
