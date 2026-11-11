import FriendCalCore
import SwiftUI

struct MeView: View {
    let store: ProposalStore
    @State private var displayName: String = ""
    @State private var isEditingName = false
    @State private var draftName: String = ""
    @State private var commitments: [Commitment] = []
    @State private var commitmentsState: CommitmentsLoadState = .loading
    @State private var showDelete = false
    @State private var toast: String?

    enum CommitmentsLoadState: Equatable {
        case loading, loaded, failed(UserFacingError)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Circle().fill(DesignTokens.FacePalette.color(for: store.currentUserID ?? UUID())).frame(width: 48, height: 48)
                        .overlay(Text(initials).textStyle(.title).foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 2) {
                        if isEditingName {
                            TextField("Name", text: $draftName).textStyle(.title)
                                .onSubmit { saveName() }
                        } else {
                            Text(displayName.isEmpty ? "You" : displayName).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                        }
                        if isDemo { demoBadge }
                    }
                    Spacer()
                    Button(isEditingName ? "Save" : "Rename") {
                        if isEditingName { saveName() } else { draftName = displayName; isEditingName = true }
                    }
                    .foregroundStyle(DesignTokens.Colors.accentHover)
                    .accessibilityIdentifier("me.rename")
                }
                .listRowBackground(DesignTokens.Colors.surface)
            }
            Section {
                NavigationLink {
                    MyCommitmentsView(commitments: commitments, state: commitmentsState)
                } label: {
                    HStack {
                        Text("My commitments").textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                        Spacer()
                        if case .loaded = commitmentsState {
                            Text("\(commitments.count)").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        }
                        Image(systemName: "chevron.right").foregroundStyle(DesignTokens.Colors.accentHover)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("me.commitmentsRow")
            } header: {
                Text("Your time").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            Section {
                Button("Sign out") {
                    LastUsedCity().clear()
                    Task { await store.signOut() }
                }
                .foregroundStyle(DesignTokens.Colors.text)
                .accessibilityIdentifier("me.signOut")
                Button("Delete account") { showDelete = true }
                    .foregroundStyle(DesignTokens.Colors.errorText)
                    .accessibilityIdentifier("me.deleteAccount")
                if let toast {
                    Text(toast).textStyle(.caption).foregroundStyle(DesignTokens.Colors.errorText)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .navigationTitle("Me")
        .navigationDestination(isPresented: $showDelete) {
            AccountDeletionView(store: store)
        }
        .task { await load() }
    }

    private var isDemo: Bool { store is InMemoryProposalStore }
    private var initials: String {
        let n = displayName.isEmpty ? "Y" : displayName
        return String(n.prefix(2)).uppercased()
    }
    private var demoBadge: some View {
        Text("DEMO").textStyle(.badge).foregroundStyle(DesignTokens.Colors.text)
            .padding(.horizontal, 6).frame(height: 20)
            .overlay(Capsule().stroke(DesignTokens.Colors.warning, lineWidth: 1))
            .accessibilityLabel("demo data, not synced")
    }
    private func saveName() {
        let t = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        displayName = t
        if let id = store.currentUserID {
            UserDefaults.standard.set(t, forKey: "FriendCalDisplayName.\(id.uuidString)")
        }
        isEditingName = false
        Task {
            do { try await store.setDisplayName(t) }
            catch { toast = "Couldn't save your name. Try again." }
        }
    }
    private func load() async {
        if let id = store.currentUserID, let cached = UserDefaults.standard.string(forKey: "FriendCalDisplayName.\(id.uuidString)") {
            displayName = cached
        } else if let user = (store as? InMemoryProposalStore)?.users.first(where: { $0.id == store.currentUserID }) {
            displayName = user.displayName
        }
        if let saved = try? await store.myDisplayName() { displayName = saved }
        do {
            let c = try await store.myCommitments(from: .now)
            commitments = c
            commitmentsState = .loaded
        } catch {
            commitmentsState = .failed(UserFacingError.map(error, action: .load))
        }
    }
}
