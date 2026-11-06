import SwiftUI
import FriendCalCore

/// Native iOS 26 TabView (Liquid Glass) with `Tab` items (D34, X3). Home content relies on the
/// automatic bottom safe-area inset, so the stealth row clears the floating bar.
struct AppTabView: View {
    @State private var home: HomeModel

    init(scenario: FixtureScenario = .fromLaunchArguments) {
        _home = State(initialValue: HomeModel(fixture: FixtureData.make(scenario)))
    }

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") { HomeView(model: home) }
            Tab("Groups", systemImage: "person.2") { StubTabView(title: "Groups") }
            Tab("Pokes", systemImage: "hand.wave") { StubTabView(title: "Pokes") }
            Tab("Invites", systemImage: "envelope") { StubTabView(title: "Invites") }
            Tab("Me", systemImage: "person.crop.circle") { StubTabView(title: "Me") }
        }
        .tint(DesignTokens.Colors.primary)
    }
}

/// Placeholder for tabs whose content is out of scope for issue #4.
struct StubTabView: View {
    let title: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Text(title).textStyle(.display).foregroundStyle(DesignTokens.Colors.text)
                .accessibilityAddTraits(.isHeader)
            Text("Coming soon").textStyle(.body).foregroundStyle(DesignTokens.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.background.ignoresSafeArea())
        .accessibilityIdentifier("stub.\(title.lowercased())")
    }
}

#Preview("Shell") { AppTabView(scenario: .populated) }
#Preview("Stub tab") { StubTabView(title: "Groups") }
