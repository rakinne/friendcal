import SwiftUI
import FriendCalCore

/// The search field shared by the place search and the city picker: magnifier, field, a 44pt clear
/// button. The identifier goes on the text field itself (a container identifier would override it).
struct SearchFieldBar: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let identifier: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DesignTokens.Colors.textMuted).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textStyle(.body).foregroundStyle(DesignTokens.Colors.text)
                .focused(focus)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DesignTokens.Colors.textMuted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.md).stroke(DesignTokens.Colors.border, lineWidth: 1))
    }
}

/// Autocomplete rows (design 2.6B): a tapped row shows a spinner and the others dim and stop taking
/// taps until it resolves. Every row is at least 44pt tall.
struct SuggestionList: View {
    let rows: [PlaceSuggestion]
    let resolvingID: String?
    let rowIdentifier: String
    let spinnerIdentifier: String
    let onSelect: (PlaceSuggestion) -> Void

    var body: some View {
        ScrollView {
            card
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { suggestion in
                let isResolving = resolvingID == suggestion.id
                let dimmed = resolvingID != nil && !isResolving
                Button { onSelect(suggestion) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).textStyle(.body).foregroundStyle(DesignTokens.Colors.text).lineLimit(1)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle).textStyle(.caption).foregroundStyle(DesignTokens.Colors.textMuted).lineLimit(1)
                            }
                        }
                        Spacer()
                        if isResolving {
                            ProgressView().tint(DesignTokens.Colors.accentHover)
                                .accessibilityIdentifier(spinnerIdentifier)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .opacity(dimmed ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(resolvingID != nil)
                .accessibilityIdentifier(rowIdentifier)
                Divider().background(DesignTokens.Colors.border).opacity(0.6)
            }
        }
        .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).fill(DesignTokens.Colors.surface))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg).stroke(DesignTokens.Colors.border, lineWidth: 1))
    }
}
