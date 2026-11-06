import SwiftUI
import FriendCalCore

@main
struct FriendCalApp: App {
    init() {
        #if DEBUG
        Self.assertFontsRegistered()
        #endif
    }

    #if DEBUG
    /// Fails loudly on a PostScript-name typo or an unregistered file instead
    /// of silently rendering SF Pro. Missing files already fail the build
    /// (font preBuildScript in project.yml).
    private static func assertFontsRegistered() {
        let missing = FontName.allCases.filter { UIFont(name: $0.rawValue, size: 12) == nil }
        assert(missing.isEmpty, "Fonts not registered: \(missing.map(\.rawValue)). Run scripts/fetch-fonts.sh and check UIAppFonts.")
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var mockSupabase = MockSupabaseService()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    MyFavesWheelView(friends: [])
                    ProposalFlowView()
                    BusyBlockView(sanitized: StealthService.SanitizedBusy(id: UUID(), userID: UUID(), range: DateRange(lower: Date.now, upper: Date.now.addingTimeInterval(3600))))
                }
            }
            .background(DesignTokens.Colors.background)
            .navigationTitle("FriendCal").navigationBarTitleDisplayMode(.inline)
        }
    }
}
