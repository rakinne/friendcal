import FriendCalCore
import SwiftUI

/// Login-first screen — Kinetic Welcome (Variant E) with hide-until-true honesty.
/// Approved: 2026-11-08, board b-20261108-095026-gciflg, selected E.
/// DESIGN.md: cream #FBF1E5 canvas, ivory card, coral primary, Cabinet Grotesk display.
struct AuthGateView: View {
    @ObservedObject var auth: AuthGateModel
    var pendingTitle: String?
    @State private var name: String = ""
    @FocusState private var isNameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canContinue: Bool { !trimmedName.isEmpty && auth.state != .signingIn }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Brand row — E's top-left wordmark with teal dot (D27 wordmark token)
                    brandRow
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    // Invited pill (only on deep-link) — teal-soft pill like F, merged into E
                    if let pendingTitle {
                        invitedPill(title: pendingTitle)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .accessibilityIdentifier("auth.invitedPill")
                    }

                    // Hero illustration — coral sun + teal foliage (no external asset)
                    AuthHeroIllustration()
                        .frame(height: min(220, proxy.size.height * 0.28))
                        .padding(.horizontal, 8)
                        .padding(.top, pendingTitle == nil ? 8 : 12)
                        .accessibilityHidden(true)

                    // Headline block — E's hero
                    VStack(spacing: 10) {
                        if let pendingTitle {
                            Text("You're in.")
                                .textStyle(.display)
                                .foregroundStyle(DesignTokens.Colors.text)
                                .multilineTextAlignment(.center)
                                .accessibilityAddTraits(.isHeader)
                            Text("Just add your name.")
                                .textStyle(.display)
                                .foregroundStyle(DesignTokens.Colors.text)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("Plan together,\nstay in sync.")
                                .textStyle(.display)
                                .foregroundStyle(DesignTokens.Colors.text)
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                                .accessibilityAddTraits(.isHeader)
                        }

                        Text(pendingTitle == nil
                             ? "The shared calendar for friend groups. No back-and-forth."
                             : "Your friends are waiting to find a time.")
                            .textStyle(.body)
                            .foregroundStyle(DesignTokens.Colors.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                    // Input card — ivory, hairline, pill CTA, friction line inside (E)
                    VStack(alignment: .leading, spacing: 14) {
                        if auth.usesApple {
                            AppleSignInSection(auth: auth)
                        }
                        if !auth.usesApple {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your name")
                                .textStyle(.label)
                                .foregroundStyle(DesignTokens.Colors.text)
                            TextField("Alex", text: $name)
                                .textStyle(.body)
                                .padding(.horizontal, 16)
                                .frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                                        .stroke(isNameFocused ? DesignTokens.Colors.text.opacity(0.18) : DesignTokens.Colors.border, lineWidth: 1)
                                )
                                .focused($isNameFocused)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit { attemptContinue() }
                                .accessibilityIdentifier("auth.nameField")
                            Text("Shown to friends on your invites")
                                .textStyle(.caption)
                                .foregroundStyle(DesignTokens.Colors.textMuted)
                        }

                        Button(action: attemptContinue) {
                            PrimaryPill(title: pendingTitle == nil ? "Continue" : "Continue to invite", isBusy: auth.state == .signingIn)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canContinue)
                        .opacity(canContinue ? 1 : 0.5)
                        .accessibilityIdentifier("auth.continue")
                        }

                        // Friction promise — the line you loved from B, now inside the card (E)
                        Text("No password. Takes 10 seconds.")
                            .textStyle(.caption)
                            .foregroundStyle(DesignTokens.Colors.textMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .accessibilityIdentifier("auth.frictionLine")

                        if case .failed(let err) = auth.state {
                            InlineError(error: err, onRetry: auth.usesApple ? nil : { Task { await auth.signIn(displayName: trimmedName) } })
                                .padding(.top, 4)
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                            .fill(DesignTokens.Colors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                            .stroke(DesignTokens.Colors.border, lineWidth: 1)
                    )
                    .shadow(color: DesignTokens.Colors.shadow.opacity(0.12), radius: 16, x: 0, y: 8)
                    .padding(.horizontal, 20)
                    .padding(.top, 22)

                    // Trust footer — faces without inflated count (hide-until-true policy)
                    // When we have a verified aggregate, show it; today we show only honest qualitative proof.
                    trustFooter
                        .padding(.top, 22)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 20))

                    Spacer(minLength: 0)
                }
                .frame(minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .onAppear { isNameFocused = !auth.usesApple }
    }

    private var brandRow: some View {
        HStack {
            Text("FriendCal")
                .font(.custom(FontName.cabinetExtrabold.rawValue, size: 28, relativeTo: .title))
                .tracking(-0.28)
                .foregroundStyle(DesignTokens.Colors.text)
            Circle()
                .fill(DesignTokens.Colors.accent)
                .frame(width: 8, height: 8)
                .padding(.leading, 2)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("FriendCal")
    }

    private func invitedPill(title: String) -> some View {
        Text("You were invited to \(title)")
            .textStyle(.caption)
            .foregroundStyle(DesignTokens.Colors.accentHover)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(DesignTokens.Colors.accentSoft))
            .overlay(Capsule().stroke(DesignTokens.Colors.accent.opacity(0.18), lineWidth: 1))
            .lineLimit(1)
    }

    private var trustFooter: some View {
        VStack(spacing: 10) {
            // Overlapping faces — fixed earth palette, overlapping 5
            HStack(spacing: -12) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(DesignTokens.FacePalette.colors[i % DesignTokens.FacePalette.colors.count])
                        .frame(width: 44, height: 44)
                        .overlay(Circle().stroke(DesignTokens.Colors.surface, lineWidth: 2))
                        .overlay(
                            Text(["M","J","S","A","R"][i])
                                .font(.custom(FontName.cabinetBold.rawValue, size: 16))
                                .foregroundStyle(Color.white.opacity(0.92))
                        )
                        .accessibilityHidden(true)
                }
            }
            // Honest — no inflated number. Descriptive, not quantitative.
            // TODO(honest-stat): When verifiedGroupsCount >= 50, show "\(verifiedCount) groups planning this week"
            Text("Friend groups planning together")
                .textStyle(.caption)
                .foregroundStyle(DesignTokens.Colors.textMuted)
                .accessibilityIdentifier("auth.trustCaption")
        }
    }

    private func attemptContinue() {
        guard canContinue else { return }
        Task { await auth.signIn(displayName: trimmedName) }
    }
}

// MARK: - Hero illustration (pure SwiftUI, no image asset)
// Matches E: coral sun with radiating strokes + teal foliage arches left/right.
// Kept as vectors so it scales and respects Kinetic Warmth without a bitmap.

private struct AuthHeroIllustration: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack {
                // Foliage — soft mint washes
                Capsule()
                    .fill(Color(hex: "#D6EFE8"))
                    .frame(width: w * 0.42, height: h * 0.38)
                    .offset(x: -w * 0.02, y: h * 0.22)
                    .opacity(0.95)
                Capsule()
                    .fill(Color(hex: "#CBE8DC"))
                    .frame(width: w * 0.36, height: h * 0.32)
                    .offset(x: w * 0.18, y: h * 0.26)

                // Leaves — teal brush-strokes (left + right clusters)
                leafCluster
                    .offset(x: -w * 0.33, y: -h * 0.08)
                leafCluster
                    .scaleEffect(x: -1, y: 1, anchor: .center)
                    .offset(x: w * 0.33, y: -h * 0.10)

                // Sun rays
                ForEach(0..<9, id: \.self) { i in
                    let angle = Double(i) * 18 - 72
                    Capsule()
                        .fill(DesignTokens.Colors.primary.opacity(i % 2 == 0 ? 0.95 : 0.72))
                        .frame(width: w * 0.06, height: h * 0.22)
                        .offset(y: -h * 0.28)
                        .rotationEffect(.degrees(angle))
                }

                // Sun body — half sunrise over horizon
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: "#FF6A32"), DesignTokens.Colors.primary], startPoint: .top, endPoint: .bottom))
                    .frame(width: w * 0.42, height: w * 0.42)
                    .offset(y: h * 0.08)

                // Horizon line (warm paper hill)
                Ellipse()
                    .fill(Color(hex: "#FFF8EF"))
                    .frame(width: w * 1.1, height: h * 0.5)
                    .offset(y: h * 0.42)
                    .overlay(
                        Ellipse()
                            .fill(Color(hex: "#E6F7F5").opacity(0.9))
                            .frame(width: w * 0.52, height: h * 0.18)
                            .offset(x: w * 0.12, y: h * 0.32)
                    )
            }
            .frame(width: w, height: h)
            .clipped()
        }
    }

    private var leafCluster: some View {
        ZStack {
            Capsule().fill(Color(hex: "#18A99A")).frame(width: 34, height: 14).rotationEffect(.degrees(-18)).offset(x: -10, y: -12)
            Capsule().fill(Color(hex: "#0E6F68")).frame(width: 28, height: 12).rotationEffect(.degrees(-42)).offset(x: -18, y: 4)
            Capsule().fill(Color(hex: "#7BC4B6")).frame(width: 32, height: 13).rotationEffect(.degrees(22)).offset(x: 8, y: -6)
            Capsule().fill(Color(hex: "#18A99A").opacity(0.85)).frame(width: 26, height: 11).rotationEffect(.degrees(38)).offset(x: 14, y: 10)
        }
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

    /// True when the store signs in with Apple (the network store); the name form is for demo data.
    var usesApple: Bool { store is AppleSignInCapable }

    func signInWithApple(idToken: String, nonce: String, displayName: String?) async {
        guard let apple = store as? AppleSignInCapable else { return }
        do {
            let id = try await apple.signInWithApple(idToken: idToken, nonce: nonce, displayName: displayName)
            if let name = displayName { UserDefaults.standard.set(name, forKey: "FriendCalDisplayName.\(id.uuidString)") }
        } catch {
            // state already set to .failed by store
        }
    }

    /// A failure that happened before the store was involved (Apple's sheet, a missing token).
    func fail(_ message: String) { state = .failed(UserFacingError(message: message)) }

    func signIn(displayName: String) async {
        do {
            _ = try await store.signIn(displayName: displayName)
            if let id = store.currentUserID {
                UserDefaults.standard.set(displayName, forKey: "FriendCalDisplayName.\(id.uuidString)")
            }
        } catch {
            // state already set to .failed by store
        }
    }
}

#Preview("Cold") {
    AuthGateView(auth: AuthGateModel(store: InMemoryProposalStore()), pendingTitle: nil)
}

#Preview("Invited") {
    AuthGateView(auth: AuthGateModel(store: InMemoryProposalStore()), pendingTitle: "Sunday Brunch")
}
