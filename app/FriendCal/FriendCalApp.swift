import SwiftUI
import FriendCalCore

@main
struct FriendCalApp: App {
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
