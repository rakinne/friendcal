import FriendCalCore
import SwiftUI

struct AccountDeletionView: View {
    let store: ProposalStore
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirm = false
    @State private var isDeleting = false
    @State private var error: UserFacingError?
    @State private var receipt: AccountDeletionReceipt?
    @FocusState private var focusDelete: Bool

    var body: some View {
        Group {
            if let receipt {
                receiptView(receipt)
            } else {
                consequenceView
            }
        }
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .navigationTitle("Delete account")
        .alert("Delete your account?", isPresented: $showConfirm) {
            Button("Delete", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your identity and anonymizes your row. Locked plans stay.")
        }
    }

    private var consequenceView: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Text("Deleting your account will:").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
            VStack(alignment: .leading, spacing: 8) {
                Text("• Cancel your open plans").textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                Text("• Release holds on those plans").textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                Text("• Keep locked plans and Busy blocks").textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                Text("• Anonymize your name to \"Someone who left\"").textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
            }
            PrimaryPill(title: "Delete account", isBusy: isDeleting, fill: DesignTokens.Colors.errorText, foreground: DesignTokens.Colors.onPrimary)
                .onTapGesture { showConfirm = true }
                .accessibilityIdentifier("deletion.delete")
                .focused($focusDelete)
            if let error { InlineError(error: error) { Task { await performDelete() } } }
            Spacer()
        }.padding(24)
    }

    private func receiptView(_ r: AccountDeletionReceipt) -> some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(DesignTokens.Colors.success)
            Text(r.alreadyDeleted ? "Account already deleted" : "Account deleted").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
            Text("Cancelled \(r.cancelledPlans) plans, released \(r.releasedHolds) holds, kept \(r.lockedPlansKept) locked plans.").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted).multilineTextAlignment(.center)
            Text("If you signed in with Apple, revoke access in Settings → Apple ID → Sign in with Apple.").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                .accessibilityIdentifier("deletion.settingsLine")
            Button("Done") { dismiss() }.accessibilityIdentifier("deletion.done")
            Spacer()
        }.padding(24)
    }

    private func performDelete() async {
        isDeleting = true
        error = nil
        do {
            let r = try await store.deleteAccount()
            // clear account-scoped name cache
            if let id = store.currentUserID {
                UserDefaults.standard.removeObject(forKey: "FriendCalDisplayName.\(id.uuidString)")
            }
            // the remembered city is per device: the next account must not inherit it
            LastUsedCity().clear()
            // suppress pending deep link per 2B
            UserDefaults.standard.set(true, forKey: "FriendCalSuppressPendingLink")
            receipt = r
        } catch {
            self.error = UserFacingError.map(error, action: .deleteAccount)
        }
        isDeleting = false
    }
}
