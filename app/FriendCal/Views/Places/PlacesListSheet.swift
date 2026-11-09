import SwiftUI
import FriendCalCore

// T2: Places list sheet — frozen sort, passed section, ellipsis menu, Bring back, plus pushing search (2.3A, 2.5A, 7.2A)

struct PlacesListSheet: View {
    var session: ProposalSession
    var onToast: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var inlineError: UserFacingError?
    /// What Retry repeats: the last place action the viewer tried.
    @State private var lastAction: (() async -> Void)?
    @State private var actingID: UUID?
    @State private var vetoTarget: PlaceBoard.Row?
    @State private var searchPath: [String] = []
    // Frozen ordering while open (2.5A): capture on appear
    @State private var frozenActive: [PlaceBoard.Row] = []
    @State private var frozenVetoed: [PlaceBoard.Row] = []

    var body: some View {
        NavigationStack(path: $searchPath) {
            listContent
                .navigationTitle("Places")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(DesignTokens.Colors.accentHover)
                            .accessibilityIdentifier("places.list.done")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            searchPath.append("search")
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 44, height: 44)
                                .foregroundStyle(DesignTokens.Colors.accentHover)
                        }
                        .buttonStyle(.plain)
                        .disabled(session.suggestAvailability != .available)
                        .accessibilityIdentifier("places.list.add")
                        .accessibilityLabel("Suggest a place")
                    }
                }
                .navigationDestination(for: String.self) { _ in
                    // Inside list: pushed search (one sheet at a time)
                    PlaceSearchContent(session: session, onToast: { msg in
                        onToast(msg)
                        refreshCounts()
                        searchPath.removeAll()
                    }, onDismiss: { searchPath.removeAll() })
                    .navigationTitle("Search places near \(session.proposal?.area?.name ?? "")")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden(false)
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Freeze order while open
            frozenActive = session.board?.active ?? []
            frozenVetoed = session.board?.vetoed ?? []
        }
        .alert(item: $vetoTarget) { target in
            Alert(
                title: Text("Pass on \(target.place.name)?"),
                message: Text("Its \(target.voteCount) votes are cleared and those friends can vote again."),
                primaryButton: .destructive(Text("Pass")) { Task { await doVeto(target) } },
                secondaryButton: .cancel()
            )
        }
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let area = session.proposal?.area {
                    Text("Near \(area.name)")
                        .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        .accessibilityIdentifier("places.list.subline")
                }

                if let error = inlineError {
                    InlineError(error: error, retryTitle: "Retry") {
                        inlineError = nil
                        if let again = lastAction { Task { await again() } }
                    }
                }

                // Active rows in frozen order
                VStack(spacing: 12) {
                    ForEach(frozenActive) { row in
                        PlaceListRow(row: row, session: session, isBusy: actingID == row.id,
                                     onVote: { await doVote(row) },
                                     onVeto: { vetoTarget = row },
                                     onWithdraw: { await doWithdraw(row) })
                    }
                }

                if !frozenVetoed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Passed by host")
                            .textStyle(.label).foregroundStyle(DesignTokens.Colors.textMuted)
                            .accessibilityIdentifier("places.list.passedHeader")
                        ForEach(frozenVetoed) { row in
                            vetoedRow(row)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(DesignTokens.Colors.background.ignoresSafeArea())
    }

    private func vetoedRow(_ row: PlaceBoard.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.place.name).textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                        .accessibilityIdentifier("places.vetoed.name")
                    if let addr = row.place.address {
                        Text(addr).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    }
                    Text("Suggested by \(session.name(of: row.place.suggestedBy))")
                        .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                }
                Spacer()
                // Bring back (host only)
                if session.isCreator {
                    Button {
                        Task { await doBringBack(row) }
                    } label: {
                        Text("Bring back").textStyle(.label).foregroundStyle(DesignTokens.Colors.accentHover)
                            .frame(minHeight: 44)
                            .padding(.horizontal, 12)
                            .background(Capsule().fill(DesignTokens.Colors.surface))
                            .overlay(Capsule().stroke(DesignTokens.Colors.accentHover, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(actingID == row.id)
                    .accessibilityIdentifier("places.bringBack")
                }
            }
            Text("Comes back with 0 votes").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface2))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .opacity(0.9)
    }

    // MARK: Actions

    private func doVote(_ row: PlaceBoard.Row) async {
        lastAction = { await doVote(row) }
        actingID = row.id
        defer { actingID = nil }
        let wasVoted = session.board?.myVotePlaceID == row.id
        do {
            if wasVoted { try await session.vote(nil); onToast("Vote removed") }
            else {
                let had = session.board?.myVotePlaceID != nil
                try await session.vote(row.id)
                // Update frozen arrays in place (order frozen, but votes update)
                onToast(had ? "Moved your vote to \(row.place.name)" : "Voted for \(row.place.name)")
            }
            inlineError = nil
            // Re-freeze from current board but keep original order? Spec: order frozen while open, update in place.
            // We keep frozenActive order, but update vote counts by re-reading session.board for matching id.
            refreshCounts()
        } catch let e as UserFacingError {
            inlineError = e
            // The session already took the server's state (design 2.8A): a place the host passed on
            // moves to Passed, one that is gone leaves the list. Re-sort so the correction shows.
            refreeze()
        } catch { inlineError = UserFacingError.map(error, action: .votePlace, creatorName: session.creatorName) }
    }

    private func doVeto(_ row: PlaceBoard.Row) async {
        lastAction = { await doVeto(row) }
        actingID = row.id
        defer { actingID = nil }
        do {
            try await session.setVeto(row.id, vetoed: true)
            inlineError = nil
            // Move row to vetoed section: refreeze
            frozenActive = session.board?.active ?? []
            frozenVetoed = session.board?.vetoed ?? []
        } catch let e as UserFacingError {
            inlineError = e
            // Stale reconcile (2.8A): refresh from session
            frozenActive = session.board?.active ?? frozenActive
            frozenVetoed = session.board?.vetoed ?? frozenVetoed
        } catch { inlineError = UserFacingError.map(error, action: .vetoPlace, creatorName: session.creatorName) }
    }

    private func doBringBack(_ row: PlaceBoard.Row) async {
        lastAction = { await doBringBack(row) }
        actingID = row.id
        defer { actingID = nil }
        do {
            try await session.setVeto(row.id, vetoed: false)
            inlineError = nil
            frozenActive = session.board?.active ?? []
            frozenVetoed = session.board?.vetoed ?? []
        } catch let e as UserFacingError {
            inlineError = e
            refreeze()
        } catch { inlineError = UserFacingError.map(error, action: .bringBack, creatorName: session.creatorName, subjectName: session.name(of: row.place.suggestedBy)) }
    }

    private func doWithdraw(_ row: PlaceBoard.Row) async {
        lastAction = { await doWithdraw(row) }
        actingID = row.id
        defer { actingID = nil }
        do {
            try await session.withdraw(row.id)
            inlineError = nil
            frozenActive = session.board?.active ?? []
            frozenVetoed = session.board?.vetoed ?? []
        } catch let e as UserFacingError { inlineError = e; refreeze() }
        catch { inlineError = UserFacingError.map(error, action: .removePlace, creatorName: session.creatorName) }
    }

    private func refreeze() {
        frozenActive = session.board?.active ?? frozenActive
        frozenVetoed = session.board?.vetoed ?? frozenVetoed
    }

    private func refreshCounts() {
        // Keep frozen order, but we don't currently display counts from frozen; we could derive from session.board
        // For simplicity, keep frozen arrays as originally ordered, but counts will be read from session.board on next render if we re-freeze in order.
        // Instead, update frozenActive's vote info from current board while preserving order
        let current = session.board
        if let current {
            var byID: [UUID: PlaceBoard.Row] = [:]
            for r in current.active + current.vetoed { byID[r.id] = r }
            frozenActive = frozenActive.compactMap { byID[$0.id] }
            // add any new active not in frozen (shouldn't happen while open, but for correctness)
            let known = Set(frozenActive.map(\.id))
            for r in current.active where !known.contains(r.id) { frozenActive.append(r) }
            frozenVetoed = current.vetoed
        }
    }
}

// MARK: - Row

private struct PlaceListRow: View {
    var row: PlaceBoard.Row
    var session: ProposalSession
    var isBusy: Bool
    var onVote: () async -> Void
    var onVeto: () -> Void
    var onWithdraw: () async -> Void

    @State private var showMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Badge
            if let badge = badgeText {
                Text(badge).textStyle(.badge).foregroundStyle(DesignTokens.Colors.accentHover)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.pill).stroke(DesignTokens.Colors.accentHover, lineWidth: 1))
                    .accessibilityIdentifier("places.badge")
            }

            HStack(alignment: .center, spacing: 8) {
                Text(row.place.name).textStyle(.title).foregroundStyle(DesignTokens.Colors.text).lineLimit(2)
                    .accessibilityIdentifier("places.name")
                Spacer(minLength: 8)
                votePill
                menuButton
            }

            if let addr = row.place.address {
                Text(addr).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            Text("Suggested by \(session.name(of: row.place.suggestedBy))")
                .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)

            // Faces + names
            if row.voteCount > 0 {
                HStack(spacing: 8) {
                    avatarStack
                    Text(namesLine).textStyle(.caption).foregroundStyle(DesignTokens.Colors.text).lineLimit(2)
                    Spacer()
                    Text("\(row.voteCount) \(row.voteCount == 1 ? "vote" : "votes")").textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("places.voters")
            } else {
                Text("No votes yet").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.noVotes")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
    }

    @ViewBuilder
    private var votePill: some View {
        if row.isMine {
            EmptyView()
        } else {
            let isVoted = session.board?.myVotePlaceID == row.id
            Button {
                Task { await onVote() }
            } label: {
                OutlinePill(title: isVoted ? "Voted" : "Vote", isVoted: isVoted, isBusy: isBusy)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityIdentifier("places.vote")
        }
    }

    private var menuButton: some View {
        Group {
            if shouldShowMenu {
                Menu {
                    if session.isCreator {
                        Button("Pass on this place", role: .destructive) { onVeto() }
                    } else if row.isMine {
                        Button("Withdraw my place", role: .destructive) { Task { await onWithdraw() } }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(DesignTokens.Colors.text)
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("places.menu")
            }
        }
    }

    private var shouldShowMenu: Bool {
        if session.isCreator && !row.place.isVetoed { return true }
        if row.isMine && !row.place.isVetoed { return true }
        return false
    }

    private var badgeText: String? {
        if row.isMine && row.voteCount > 0, session.board?.leaderID == row.id { return "YOURS" }
        if row.voteCount == 0 { return nil }
        if let board = session.board, board.tiedWith.contains(row.id) || (!board.tiedWith.isEmpty && board.leaderID == row.id) { return "TIED" }
        if session.board?.leaderID == row.id { return "LEADING" }
        return nil
    }

    private var avatarStack: some View {
        HStack(spacing: -6) {
            ForEach(row.voters.prefix(4), id: \.self) { vid in
                avatar(for: vid).overlay(Circle().stroke(DesignTokens.Colors.surface, lineWidth: 1.5))
            }
            if row.voters.count > 4 {
                Text("+\(row.voters.count - 4)").textStyle(.badge).foregroundStyle(DesignTokens.Colors.text)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(DesignTokens.Colors.surface))
                    .overlay(Circle().stroke(DesignTokens.Colors.border, lineWidth: 1))
            }
        }
    }

    private func avatar(for id: UUID) -> some View {
        Group {
            if let member = session.members.first(where: { $0.id == id }) {
                FriendAvatar(member: member, size: 28, style: .badge)
            } else {
                DepartedAvatar(size: 28)
            }
        }
    }

    private var namesLine: String {
        let names = row.voters.map { session.name(of: $0) }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        case 4: return "\(names[0]), \(names[1]), \(names[2]) and \(names[3])"
        default: return "\(names[0]), \(names[1]), \(names[2]) and \(names.count - 3) more"
        }
    }
}

#Preview("Places list") {
    let s = ProposalSession(fixture: FixtureData.make(.placesVoting))
    PlacesListSheet(session: s)
}

#Preview("Places list vetoed") {
    let s = ProposalSession(fixture: FixtureData.make(.placesVetoed))
    PlacesListSheet(session: s)
}

