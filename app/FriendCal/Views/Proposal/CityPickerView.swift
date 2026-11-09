import SwiftUI
import FriendCalCore

/// The host's city picker (design PL-5, 3.1A), pushed inside New plan and Edit plan. Typing searches
/// cities through `PlaceSearching.cities(for:)`; tapping a row resolves it to a `SearchArea` (name and
/// center), hands it to `onPick` and pops. There is deliberately no way to clear the city: a plan's city
/// can be replaced, never removed (R1; the store refuses a clear with FC_AREA_REQUIRED).
///
/// States from the design's interaction table: a spinner while a search is in flight, "Type at least 2
/// letters" under two characters, a spinner on the tapped row while it resolves, and the two picker
/// errors ("No city found. Try another name." and the offline sentence).
struct CityPickerView: View {
    var onPick: (SearchArea) -> Void
    /// Previews and tests pass one; the app leaves it nil and gets the provider's searcher.
    var searcher: (any PlaceSearching)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.placeSearch) private var provider
    @State private var searcherBox = SearcherBox()
    @State private var query = ""
    @State private var results: [PlaceSuggestion] = []
    @State private var message: String?
    @State private var isSearching = false
    @State private var resolvingID: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private var activeSearcher: any PlaceSearching { searcher ?? searcherBox.resolve(provider) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SearchFieldBar(prompt: "Search cities", text: $query, focus: $fieldFocused, identifier: "city.search.field")

                if trimmedQuery.count < 2 {
                    Text("Type at least 2 letters")
                        .textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted)
                        .accessibilityIdentifier("city.hint")
                }

                if let message {
                    Text(message)
                        .textStyle(.caption).foregroundStyle(DesignTokens.Colors.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("city.error")
                }

                if isSearching && results.isEmpty {
                    ProgressView().tint(DesignTokens.Colors.accentHover)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("city.searching")
                }

                if !results.isEmpty && message == nil {
                    SuggestionList(rows: results, resolvingID: resolvingID,
                                   rowIdentifier: "city.result", spinnerIdentifier: "city.spinner") { suggestion in
                        Task { await select(suggestion) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .navigationTitle("City")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, newValue in scheduleSearch(for: newValue) }
        .onAppear { fieldFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: Search

    private func scheduleSearch(for raw: String) {
        searchTask?.cancel()
        message = nil
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { @MainActor in
            // MapKitPlaceSearch debounces 250 ms itself; this wait only coalesces fast typing.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await run(trimmed)
        }
    }

    @MainActor
    private func run(_ query: String) async {
        // A superseded search must not clear the spinner the newer one just raised.
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            for try await rows in activeSearcher.cities(for: query) {
                guard !Task.isCancelled else { return }
                results = rows
                // MapKit reports "nothing matched" as an empty batch, the fixture as a thrown noResult.
                message = rows.isEmpty ? PlaceSearchCopy.message(for: .noResult) : nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            message = PlaceSearchCopy.message(for: (error as? PlaceSearchError) ?? .offline)
        }
    }

    // MARK: Select

    @MainActor
    private func select(_ suggestion: PlaceSuggestion) async {
        guard resolvingID == nil else { return }
        resolvingID = suggestion.id
        message = nil
        defer { resolvingID = nil }
        do {
            let area = try await activeSearcher.resolveCity(suggestion)
            // The same check the SQL constraint makes; a city it would refuse never reaches the form.
            guard area.isValid else {
                message = PlaceSearchCopy.message(for: .noResult)
                return
            }
            onPick(area)
            dismiss()
        } catch {
            message = PlaceSearchCopy.message(for: (error as? PlaceSearchError) ?? .offline)
        }
    }
}

#Preview("City picker") {
    NavigationStack { CityPickerView(onPick: { _ in }, searcher: FixturePlaceSearch()) }
}
