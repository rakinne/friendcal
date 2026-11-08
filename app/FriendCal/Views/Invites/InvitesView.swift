import SwiftUI
import Observation
import FriendCalCore

/// The Invites list's small model (issue #5 C9, P6): `store.proposals()` only, no overlap counts.
@MainActor
@Observable
final class ProposalListModel {
    enum State: Equatable {
        case loading
        case empty
        case error(UserFacingError)
        case rows([ProposalSummary])
    }

    let store: ProposalStore
    var now: () -> Date
    private(set) var state: State = .loading

    init(store: ProposalStore, now: @escaping () -> Date = { .now }) {
        self.store = store
        self.now = now
    }

    func load() async {
        if case .rows = state {} else { state = .loading }
        do {
            let rows = Self.ordered(try await store.proposals(), now: now())
            state = rows.isEmpty ? .empty : .rows(rows)
        } catch {
            state = .error(UserFacingError.map(error, action: .load))
        }
    }

    /// Design 1.7A: locked with an upcoming date first (soonest first), then requesting by window
    /// start, then past plans (window ended or locked time passed), most recent first.
    static func ordered(_ rows: [ProposalSummary], now: Date) -> [ProposalSummary] {
        let current = rows.filter { !isPast($0.proposal, now: now) }
        let locked = current.filter(\.proposal.isLocked).sorted { ($0.proposal.lockedDate ?? .distantFuture) < ($1.proposal.lockedDate ?? .distantFuture) }
        let requesting = current.filter { !$0.proposal.isLocked }.sorted { $0.proposal.window.lowerBound < $1.proposal.window.lowerBound }
        let past = rows.filter { isPast($0.proposal, now: now) }.sorted { relevantDate($0.proposal) > relevantDate($1.proposal) }
        return locked + requesting + past
    }

    static func isPast(_ p: Proposal, now: Date) -> Bool {
        if p.isLocked, let end = p.lockedEnd { return end <= now }
        return p.window.upperBound <= now
    }

    private static func relevantDate(_ p: Proposal) -> Date {
        p.isLocked ? (p.lockedEnd ?? p.window.upperBound) : p.window.upperBound
    }
}

/// The Invites tab (issue #5 design 1.6A, 1.7A, 2.2A, 7.2A): "Invites" in `display` on the cream
/// canvas, card rows with a status line and a Hosting badge, a trailing "+" (New plan), the empty
/// state's "Start a plan", loading and error states. Rows push the invite; a deep link sets the path.
struct InvitesView: View {
    let store: ProposalStore
    @Binding var path: [UUID]
    var members: [HomeMember] = []
    var clock: () -> Date = { .now }
    var calendar: Calendar = .current
    @State private var list: ProposalListModel
    @State private var showCreate = false

    init(store: ProposalStore, path: Binding<[UUID]>, members: [HomeMember] = [], clock: @escaping () -> Date = { .now }, calendar: Calendar = .current) {
        self.store = store
        _path = path
        self.members = members
        self.clock = clock
        self.calendar = calendar
        _list = State(initialValue: ProposalListModel(store: store, now: clock))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Invites").textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 4)
                    switch list.state {
                    case .loading: ForEach(0..<3, id: \.self) { _ in skeletonRow }
                    case .empty: empty
                    case .error(let error): errorState(error)
                    case .rows(let rows): ForEach(rows) { row($0) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(DesignTokens.Colors.background.ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus").foregroundStyle(DesignTokens.Colors.accentHover).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("New plan")
                    .accessibilityIdentifier("invites.new")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                LockedInviteDestination(store: store, id: id, members: members, clock: clock, onGoToInvites: { path = [] })
            }
            .task { await list.load() }
            .onChange(of: path) { _, new in if new.isEmpty { Task { await list.load() } } }
            .sheet(isPresented: $showCreate, onDismiss: { Task { await list.load() } }) {
                CreateProposalSheet(mode: .create(store, calendar: calendar, now: clock), onCreated: { p in path = [p.id] })
                    .presentationDetents([.large])
            }
        }
    }

    // MARK: Rows

    private func row(_ summary: ProposalSummary) -> some View {
        let p = summary.proposal
        let past = ProposalListModel.isPast(p, now: clock())
        return NavigationLink(value: p.id) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.title).textStyle(.title).foregroundStyle(DesignTokens.Colors.text).lineLimit(1)
                    HStack(spacing: 6) {
                        if p.isLocked { SwiftUI.Circle().fill(DesignTokens.Colors.primary).frame(width: 6, height: 6) }
                        Text(status(summary)).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if summary.isHosting {
                    Text("HOSTING").textStyle(.badge).tracking(0.4).foregroundStyle(DesignTokens.Colors.textMuted)
                        .padding(.horizontal, 6).frame(height: 20)
                        .overlay(Capsule().stroke(DesignTokens.Colors.textMuted, lineWidth: 1))
                }
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(DesignTokens.Colors.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
            .opacity(past ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([p.title, status(summary), summary.isHosting ? "hosting" : nil, past ? "past" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("invites.row")
    }

    /// "3 of 10 joined · Nov 9–22" or "Locked · Sat, Nov 14 · 10:00–12:00" (the same for everyone, 7.2A).
    private func status(_ summary: ProposalSummary) -> String {
        let p = summary.proposal
        if p.isLocked, let window = p.lockedWindow {
            return "Locked · \(DateText.day(window.lowerBound, calendar: calendar, locale: .current)) · \(DateText.timeRange(window, calendar: calendar, locale: .current))"
        }
        return "\(summary.joinedCount) of \(p.headcount) joined · \(DateText.dayRange(p.window, calendar: calendar, locale: .current))"
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(Color.skeleton).frame(width: 120, height: 14)
                Capsule().fill(Color.skeleton).frame(width: 180, height: 10)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
        .accessibilityHidden(true)
        .accessibilityIdentifier("invites.skeleton")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("No invites yet").textStyle(.title).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityIdentifier("invites.empty")
            Text("When a friend sends you a plan, it lands here.").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button { showCreate = true } label: {
                Text("Start a plan").textStyle(.button).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 20).frame(minHeight: 52)
                    .background(Capsule().fill(DesignTokens.Colors.accentHover))
            }
            .accessibilityIdentifier("invites.start")
        }
        .padding(.top, 8)
    }

    private func errorState(_ error: UserFacingError) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(error.message).textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityIdentifier("invites.error")
            if let details = error.details {
                DisclosureGroup("Details") {
                    Text(details).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        .accessibilityIdentifier("invites.errorDetails")
                }
                .tint(DesignTokens.Colors.textMuted)
            }
            Button { Task { await list.load() } } label: {
                Text("Retry").textStyle(.button).foregroundStyle(DesignTokens.Colors.onPrimary)
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .background(Capsule().fill(DesignTokens.Colors.accentHover))
            }
            .accessibilityIdentifier("invites.retry")
        }
    }
}

#Preview("Invites, list") {
    let fixture = FixtureData.make(.invites)
    let store = FixtureData.store(fixture, clock: { .now })
    return InvitesView(store: store, path: .constant([]), members: fixture.members)
}

#Preview("Invites, empty") {
    InvitesView(store: InMemoryProposalStore(currentUserID: UUID()), path: .constant([]))
}
