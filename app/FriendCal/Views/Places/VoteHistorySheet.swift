import SwiftUI
import FriendCalCore

/// A read-only list of who voted for what. Two entry points: "How the vote went" on a locked plan (every
/// place, the winner first) and the leader card's voters control (`only` names the one place). Departed
/// friends appear with the neutral glyph and the name "A friend" (design 5.3A).
struct VoteHistorySheet: View {
    var session: ProposalSession
    /// Limits the list to one place (the voters control); nil lists every place.
    var only: UUID?
    @Environment(\.dismiss) private var dismiss

    private var rows: [PlaceBoard.Row] {
        guard let board = session.board else { return [] }
        let all = board.active.filter { only == nil || $0.id == only }
        let winnerID = session.winner?.id
        return all.sorted { a, b in
            if (a.id == winnerID) != (b.id == winnerID) { return a.id == winnerID }
            return a.voteCount > b.voteCount
        }
    }

    private var passed: [Place] { only == nil ? (session.board?.vetoed.map(\.place) ?? []) : [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.id) { row in card(row) }
                    if !passed.isEmpty {
                        Text("Passed by host").textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted).padding(.top, 8)
                        ForEach(passed) { place in
                            Text(place.name).textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.horizontal, 16)
                                .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface2))
                        }
                    }
                }
                .padding(20)
            }
            .background(DesignTokens.Colors.background.ignoresSafeArea())
            .navigationTitle(only == nil ? "How the vote went" : "Who voted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(DesignTokens.Colors.accentHover)
                        .accessibilityIdentifier("history.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func card(_ row: PlaceBoard.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.place.name).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("history.place")
                Spacer(minLength: 8)
                if row.id == session.winner?.id {
                    Text("WINNER").textStyle(.badge).foregroundStyle(DesignTokens.Colors.accentHover)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.pill).stroke(DesignTokens.Colors.accentHover, lineWidth: 1))
                }
                Text("\(row.voteCount) \(row.voteCount == 1 ? "vote" : "votes")").textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
            }
            if row.voters.isEmpty {
                Text("No votes").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
            } else {
                ForEach(row.voters, id: \.self) { id in
                    HStack(spacing: 10) {
                        avatar(id)
                        Text(session.name(of: id)).textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("history.voter")
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
    }

    @ViewBuilder
    private func avatar(_ id: UUID) -> some View {
        if let member = session.members.first(where: { $0.id == id }) {
            FriendAvatar(member: member, size: 28, style: .badge)
        } else {
            DepartedAvatar(size: 28)
        }
    }
}
