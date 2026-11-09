import SwiftUI
import FriendCalCore

// T2/T3: MapKit search screens (PL-4, decisions 1.5A, 2.2A, 2.6B, 7.1A, 7.2A)
// - Prompt + caption, 2-letter hint, spinner on tapped row + dim others, inline duplicate panel, success toast.
// - Two presentations: sheet from main screen (PlaceSearchSheet) and pushed inside PlacesListSheet (PlaceSearchContent).

// MARK: - Search content (shared)

struct PlaceSearchContent: View {
    var session: ProposalSession
    /// Previews and tests pass one; the app leaves it nil and gets the provider's searcher.
    var searcher: (any PlaceSearching)? = nil
    /// Called with the finished toast text ("Added Juniper Table", "Moved your vote to Cafe Lola").
    var onToast: (String) -> Void
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismissAction
    @Environment(\.placeSearch) private var provider
    @State private var searcherBox = SearcherBox()
    @State private var query = ""
    @State private var results: [PlaceSuggestion] = []
    @State private var searchError: String?
    @State private var inlineError: UserFacingError?
    @State private var resolvingID: String?
    /// The suggestion whose store write failed, so Retry can replay it (`resolvingID` is cleared on failure).
    @State private var failedSuggestion: PlaceSuggestion?
    @State private var duplicate: DuplicateState?
    @FocusState private var fieldFocused: Bool
    @State private var searchTask: Task<Void, Never>?

    enum DuplicateState: Equatable {
        case own(Place)
        case vetoed(Place)
        case other(Place, name: String)
    }

    private var area: SearchArea? { session.proposal?.area }
    private var activeSearcher: any PlaceSearching { searcher ?? searcherBox.resolve(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            if let area {
                Text("Within \(Int(SearchArea.radiusMeters / 1000)) km of \(area.name)")
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.search.caption")
            }

            if let error = searchError {
                Text(error)
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.errorText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("places.search.error")
            }

            if let err = inlineError {
                InlineError(error: err, retryTitle: "Retry") {
                    if let suggestion = failedSuggestion {
                        Task { await select(suggestion) }
                    } else {
                        inlineError = nil
                    }
                }
            }

            if let dup = duplicate {
                duplicatePanel(dup)
            }

            content
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .onChange(of: query) { _, newValue in scheduleSearch(for: newValue) }
        .onAppear { fieldFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: Field

    private var searchField: some View {
        SearchFieldBar(prompt: prompt, text: $query, focus: $fieldFocused, identifier: "places.search.field")
    }

    private var prompt: String {
        if let area { return "Search places near \(area.name)" }
        return "Search places"
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 2 {
            Text("Type at least 2 letters")
                .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                .accessibilityIdentifier("places.search.hint")
        } else if !results.isEmpty && searchError == nil {
            resultsList
        }
    }

    private var resultsList: some View {
        SuggestionList(rows: results, resolvingID: resolvingID,
                       rowIdentifier: "places.search.result", spinnerIdentifier: "places.search.spinner") { suggestion in
            Task { await select(suggestion) }
        }
    }

    // MARK: Duplicate panel

    private func duplicatePanel(_ state: DuplicateState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .vetoed:
                Text("The host passed on this")
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.duplicate.message")
            case .own(let place):
                Text("You already suggested this")
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.duplicate.message")
                Text(place.name).textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
            case .other(let place, let name):
                Text("Already suggested by \(name)")
                    .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                    .accessibilityIdentifier("places.duplicate.message")
                HStack(spacing: 8) {
                    Text(place.name).textStyle(.body).foregroundStyle(DesignTokens.Colors.text).lineLimit(1)
                    Spacer()
                    Button {
                        Task { await voteForDuplicate(place) }
                    } label: {
                        OutlinePill(title: "Vote")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("places.duplicate.vote")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface2))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(DesignTokens.Colors.border, lineWidth: 1))
    }

    // MARK: Search

    private func scheduleSearch(for raw: String) {
        searchTask?.cancel()
        inlineError = nil
        duplicate = nil
        searchError = nil
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            searchError = nil
            return
        }
        guard area != nil else {
            // FC_NO_AREA copy. Defensive: the Suggest pill is not offered without a city.
            searchError = "\(session.creatorName ?? "The host") hasn't picked a city yet."
            return
        }
        searchTask = Task { @MainActor in
            // MapKitPlaceSearch debounces 250 ms itself; this short wait only coalesces fast typing
            // so a fixture search does not start a stream per keystroke.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await runSearch(query: trimmed)
        }
    }

    @MainActor
    private func runSearch(query: String) async {
        guard let area else { return }
        do {
            for try await rows in activeSearcher.suggestions(for: query, in: area) {
                guard !Task.isCancelled else { return }
                results = rows
                // MapKit reports "nothing matched" as an empty batch, the fixture as a thrown noResult.
                // Both show the same sentence.
                searchError = rows.isEmpty ? PlaceSearchCopy.message(for: .noResult, areaName: area.name) : nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            searchError = Self.searchMessage(for: error, area: area)
        }
    }

    /// Search failures arrive as `PlaceSearchError`; anything else (a transport error that escaped the
    /// MapKit mapping) is read as offline.
    private static func searchMessage(for error: Error, area: SearchArea) -> String {
        PlaceSearchCopy.message(for: (error as? PlaceSearchError) ?? .offline, areaName: area.name)
    }

    // MARK: Select

    @MainActor
    private func select(_ suggestion: PlaceSuggestion) async {
        guard let area else { return }
        guard resolvingID == nil else { return }
        resolvingID = suggestion.id
        failedSuggestion = nil
        inlineError = nil
        searchError = nil
        duplicate = nil
        do {
            let newPlace = try await activeSearcher.resolve(suggestion, in: area)
            // duplicate check (client-side same as server)
            if let existing = PlaceBoard.existing(matching: newPlace, in: session.places) {
                if existing.isVetoed {
                    duplicate = .vetoed(existing)
                } else if existing.suggestedBy == session.currentUserID {
                    duplicate = .own(existing)
                } else {
                    let name = session.name(of: existing.suggestedBy)
                    duplicate = .other(existing, name: name)
                }
                resolvingID = nil
                return
            }
            // suggest
            let saved = try await session.suggest(newPlace)
            onToast("Added \(saved.name)")
            close()
        } catch let err as PlaceSearchError {
            // A resolve failure (outside the area, throttled, offline) is a search problem, not a store one.
            searchError = PlaceSearchCopy.message(for: err, areaName: area.name)
        } catch {
            // `session.suggest` already throws UserFacingError; `map` returns one unchanged.
            inlineError = UserFacingError.map(error, action: .suggestPlace, creatorName: session.creatorName)
            failedSuggestion = suggestion
        }
        resolvingID = nil
    }

    @MainActor
    private func voteForDuplicate(_ place: Place) async {
        do {
            let hadVote = session.board?.myVotePlaceID != nil
            try await session.vote(place.id)
            onToast(hadVote ? "Moved your vote to \(place.name)" : "Voted for \(place.name)")
            close()
        } catch {
            inlineError = UserFacingError.map(error, action: .votePlace, creatorName: session.creatorName)
        }
    }

    private func close() {
        if let onDismiss { onDismiss() }
        else { dismissAction() }
    }
}

// MARK: - Sheet wrapper (from main screen)

struct PlaceSearchSheet: View {
    var session: ProposalSession
    /// Called with the finished toast text ("Added Juniper Table", "Moved your vote to Cafe Lola").
    var onToast: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlaceSearchContent(session: session, onToast: onToast) {
                dismiss()
            }
            .navigationTitle("Suggest a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(DesignTokens.Colors.accentHover)
                        .accessibilityIdentifier("places.search.cancel")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Previews

#Preview("Search - fixture") {
    let s = ProposalSession(fixture: FixtureData.make(.placesVoting))
    NavigationStack { PlaceSearchContent(session: s, searcher: FixturePlaceSearch(), onToast: { _ in }) }
        .background(DesignTokens.Colors.background)
}

#Preview("Search sheet") {
    let s = ProposalSession(fixture: FixtureData.make(.placesEmpty))
    PlaceSearchSheet(session: s) { _ in }
        .environment(\.placeSearch, .fixture)
}

