import SwiftUI
import FriendCalCore

// T1: Places section — leader card variants (1.1A, 1.2A, 2.1A, 2.7A, 6.1A, 7.5A)
// Shown below progress line with 24pt gap. No coral in section.
struct PlacesSection: View {
    var session: ProposalSession
    var onToast: (String) -> Void = { _ in }
    /// The host's "Choose a city" pill: the screen opens Edit plan with the city picker pushed.
    var onChooseCity: () -> Void = {}
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var votingID: UUID?
    @State private var inlineError: UserFacingError?
    @State private var sheet: PresentedSheet?

    /// The two sheets this section opens, behind one modifier. (Search from inside the list is pushed
    /// by the list itself: one sheet at a time, design PL-4.)
    private enum PresentedSheet: String, Identifiable {
        case search, list
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer().frame(height: 12) // 24pt gap total with content's 16 spacing; 12 here = 28? keep 24 visual
                .accessibilityHidden(true)

            Text("Where?")
                .textStyle(.display)
                .foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("places.heading")

            subline

            if let error = inlineError {
                InlineError(error: error, retryTitle: "Retry") { inlineError = nil }
            }

            if session.proposal?.status == .locked {
                lockedSection
            } else if session.proposal?.area == nil {
                noCitySection
            } else if session.board?.active.isEmpty == true {
                emptySection
            } else {
                leaderCardSection
            }

            suggestOrCap
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .search: PlaceSearchSheet(session: session, onToast: onToast)
            case .list: PlacesListSheet(session: session, onToast: onToast)
            }
        }
    }

    // MARK: Subline (PL-1)
    private var subline: some View {
        Group {
            if let area = session.proposal?.area {
                let host = session.isCreator ? "you" : (session.creatorName ?? "the host")
                Text("Near \(area.name) · Voting closes when \(host) \(session.isCreator ? "lock" : "locks") the date")
                    .textStyle(.caption)
                    .foregroundStyle(DesignTokens.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("places.subline")
            } else if session.proposal?.status != .locked {
                // no city friends subline is handled in noCitySection; still placeholder
                EmptyView()
            }
        }
    }

    // MARK: Locked
    private var lockedSection: some View {
        Group {
            if let winner = session.winner {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(DesignTokens.Colors.accentHover).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(winner.name).textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                                .accessibilityIdentifier("places.winner.name")
                            if let addr = winner.address {
                                Text(addr).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                            }
                        }
                        Spacer()
                        Link(destination: URL(string: "http://maps.apple.com/?q=\(winner.latitude),\(winner.longitude)")!) {
                            Text("Open in Maps").textStyle(.label).foregroundStyle(DesignTokens.Colors.accentHover)
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("places.winner.maps")
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))

                    Button {} label: {
                        HStack { Text("How the vote went").textStyle(.label).foregroundStyle(DesignTokens.Colors.accentHover); Spacer(); Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(DesignTokens.Colors.accentHover) }
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("places.history")
                }
            } else {
                Text("No place was picked.")
                    .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.noWinner")
            }
        }
    }

    // MARK: No city
    private var noCitySection: some View {
        Group {
            if session.isCreator {
                Button {
                    onChooseCity()
                } label: {
                    OutlinePill(title: "Choose a city", fullWidth: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("places.chooseCity")
            } else {
                Text("Places open once \(session.creatorName ?? "the host") picks a city.")
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.noCity.friend")
            }
        }
    }

    // MARK: Empty (no places)
    private var emptySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No places yet. Suggest where to go.")
                .textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                .accessibilityIdentifier("places.empty")
        }
    }

    // MARK: Leader card
    private var leaderCardSection: some View {
        Group {
            if let board = session.board, let cardRow = leaderRow(board: board) {
                leaderCard(row: cardRow, board: board)
            }
        }
    }

    private func leaderRow(board: PlaceBoard) -> PlaceBoard.Row? {
        if let leaderID = board.leaderID, let r = board.active.first(where: { $0.id == leaderID }) { return r }
        // zero votes or no leader: show first by vote order (createdAt)
        return board.active.first
    }

    private func leaderCard(row: PlaceBoard.Row, board: PlaceBoard) -> some View {
        let badge = badgeText(row: row, board: board)
        let isMine = row.isMine
        let iVoted = row.iVoted
        let voteCount = row.voteCount
        let voters = row.voters
        let isTied = !board.tiedWith.isEmpty && board.leaderID == row.id

        return VStack(alignment: .leading, spacing: 8) {
            // Badge
            if let badge {
                Text(badge)
                    .textStyle(.badge)
                    .foregroundStyle(DesignTokens.Colors.accentHover)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.pill).stroke(DesignTokens.Colors.accentHover, lineWidth: 1))
                    .accessibilityIdentifier("places.badge")
            } else if voteCount == 0 {
                // no badge, per spec
                EmptyView()
            }

            // Name + Vote pill — stacks below on a11y or narrow
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    Text(row.place.name).textStyle(.title).foregroundStyle(DesignTokens.Colors.text).lineLimit(2).accessibilityIdentifier("places.name")
                    Spacer(minLength: 8)
                    voteButton(row: row, board: board)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.place.name).textStyle(.title).foregroundStyle(DesignTokens.Colors.text).lineLimit(2).accessibilityIdentifier("places.name")
                    voteButton(row: row, board: board).frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let addr = row.place.address {
                Text(addr).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            Text("Suggested by \(session.name(of: row.place.suggestedBy))")
                .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)

            // Faces + names/count as one 44pt control
            if voteCount > 0 || !voters.isEmpty {
                Button {
                    onToast("Who voted sheet coming soon")
                } label: {
                    HStack(spacing: 8) {
                        avatarStack(voters: voters)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(namesLine(voters: voters)).textStyle(.caption).foregroundStyle(DesignTokens.Colors.text).lineLimit(2)
                            if isTied, let otherName = tiedOtherName(board: board) {
                                Text("\(row.place.name) was suggested first, so it wins a tie")
                                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                            }
                        }
                        Spacer()
                        Text("\(voteCount) \(voteCount == 1 ? "vote" : "votes")").textStyle(.mono).foregroundStyle(DesignTokens.Colors.text)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(voteCount) votes from \(namesLine(voters: voters)). Double tap to see who voted.")
                .accessibilityIdentifier("places.voters")
            } else {
                Text("No votes yet").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted).accessibilityIdentifier("places.noVotes")
            }

            if let myVoteID = board.myVotePlaceID, let myPlace = session.places.first(where: { $0.id == myVoteID }) {
                Text("Your vote: \(myPlace.name)").textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.yourVote")
            }

            Divider().background(DesignTokens.Colors.border)

            // View all row
            let total = board.active.count + board.vetoed.count
            if total > 1 || board.vetoed.count > 0 {
                Button {
                    sheet = .list
                } label: {
                    HStack {
                        Text("View all \(total) places").textStyle(.label).foregroundStyle(DesignTokens.Colors.accentHover)
                        Spacer()
                        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(DesignTokens.Colors.accentHover)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("places.viewAll")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
        .shadow(color: DesignTokens.Colors.shadow.opacity(0.12), radius: 12, x: 0, y: 6)
        .accessibilityElement(children: .contain)
    }

    private func badgeText(row: PlaceBoard.Row, board: PlaceBoard) -> String? {
        if row.isMine && board.leaderID == row.id && row.voteCount > 0 { return "YOURS" }
        if row.voteCount == 0 { return nil }
        if board.tiedWith.contains(row.id) || (!board.tiedWith.isEmpty && board.leaderID == row.id) { return "TIED" }
        if board.leaderID == row.id { return "LEADING" }
        return nil
    }

    private func tiedOtherName(board: PlaceBoard) -> String? {
        board.tiedWith.first.flatMap { id in session.places.first(where: { $0.id == id })?.name }
    }

    private func voteButton(row: PlaceBoard.Row, board: PlaceBoard) -> some View {
        Group {
            if row.isMine {
                EmptyView().accessibilityHidden(true) // no Vote pill on own place
            } else {
                let isVoted = board.myVotePlaceID == row.id
                let busy = votingID == row.id
                Button {
                    Task { await doVote(row: row, isVoted: isVoted) }
                } label: {
                    OutlinePill(title: isVoted ? "Voted" : "Vote", isVoted: isVoted, isBusy: busy)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel(isVoted ? "Voted for \(row.place.name). Double tap to remove your vote." : "Vote for \(row.place.name)")
                .accessibilityIdentifier("places.vote")
            }
        }
    }

    private func doVote(row: PlaceBoard.Row, isVoted: Bool) async {
        votingID = row.id
        defer { votingID = nil }
        do {
            if isVoted {
                try await session.vote(nil)
                onToast("Vote removed")
            } else {
                let hadVote = session.board?.myVotePlaceID != nil
                try await session.vote(row.id)
                onToast(hadVote ? "Moved your vote to \(row.place.name)" : "Voted for \(row.place.name)")
            }
            inlineError = nil
        } catch let e as UserFacingError {
            inlineError = e
        } catch {
            inlineError = UserFacingError.map(error, action: .votePlace, creatorName: session.creatorName)
        }
    }

    private func avatarStack(voters: [UUID]) -> some View {
        HStack(spacing: -6) {
            ForEach(voters.prefix(4), id: \.self) { vid in
                avatar(for: vid)
                    .overlay(Circle().stroke(DesignTokens.Colors.surface, lineWidth: 1.5))
            }
            if voters.count > 4 {
                Text("+\(voters.count - 4)").textStyle(.badge).foregroundStyle(DesignTokens.Colors.text)
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
                // departed friend
                Image(systemName: "person.fill").imageScale(.small).foregroundStyle(DesignTokens.Colors.textMuted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(DesignTokens.Colors.surface2))
                    .overlay(Circle().stroke(DesignTokens.Colors.border, lineWidth: 1))
            }
        }
    }

    private func namesLine(voters: [UUID]) -> String {
        let names = voters.map { session.name(of: $0) }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        case 4: return "\(names[0]), \(names[1]), \(names[2]) and \(names[3])"
        default: return "\(names[0]), \(names[1]), \(names[2]) and \(names.count - 3) more"
        }
    }

    // MARK: Suggest / cap
    @ViewBuilder
    private var suggestOrCap: some View {
        if session.proposal?.status == .locked { EmptyView() }
        else if session.proposal?.area == nil { EmptyView() } // handled in noCity
        else {
            switch session.suggestAvailability {
            case .available:
                Button {
                    sheet = .search
                } label: {
                    OutlinePill(title: "Suggest a place", fullWidth: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("places.suggest")
            case .personalCap:
                Text("You've suggested \(PlaceBoard.perPersonLimit) places. Withdraw one to add another.")
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.cap.personal")
            case .planFull:
                Text("This plan already has \(PlaceBoard.planLimit) places.")
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.cap.plan")
            case .noCity, .locked, .notMember:
                EmptyView()
            }
        }
    }
}

#Preview("Places – voting") {
    NavigationStack {
        ScrollView {
            VStack { PlacesSection(session: ProposalSession(fixture: FixtureData.make(.placesVoting))) }
                .padding(20)
        }.background(DesignTokens.Colors.background)
    }
}
#Preview("Places – empty") {
    NavigationStack {
        ScrollView {
            VStack { PlacesSection(session: ProposalSession(fixture: FixtureData.make(.placesEmpty))) }
                .padding(20)
        }.background(DesignTokens.Colors.background)
    }
}
#Preview("Places – tied") {
    NavigationStack {
        ScrollView {
            VStack { PlacesSection(session: ProposalSession(fixture: FixtureData.make(.placesTied))) }
                .padding(20)
        }.background(DesignTokens.Colors.background)
    }
}
#Preview("Places – zero votes") {
    NavigationStack {
        ScrollView {
            VStack { PlacesSection(session: ProposalSession(fixture: FixtureData.make(.placesZeroVotes))) }
                .padding(20)
        }.background(DesignTokens.Colors.background)
    }
}
#Preview("Places – capped") {
    NavigationStack {
        ScrollView {
            VStack { PlacesSection(session: ProposalSession(fixture: FixtureData.make(.placesCapped))) }
                .padding(20)
        }.background(DesignTokens.Colors.background)
    }
}
#Preview("Places – no city host") {
    NavigationStack {
        ScrollView {
            VStack { PlacesSection(session: ProposalSession(fixture: FixtureData.make(.noCityHost))) }
                .padding(20)
        }.background(DesignTokens.Colors.background)
    }
}
#Preview("Places – locked") {
    NavigationStack {
        ScrollView {
            VStack { PlacesSection(session: ProposalSession(fixture: FixtureData.make(.placesLocked))) }
                .padding(20)
        }.background(DesignTokens.Colors.background)
    }
}
