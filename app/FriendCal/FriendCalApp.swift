import SwiftUI

@main
struct FriendCalApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    // Preview data mirroring Friendsgivemas screenshots
    var body: some View {
        NavigationStack {
            MyFavesWheelView(friends: [])
            Text("FriendCal — Phase 1 scaffold")
                .foregroundStyle(.secondary)
        }
    }
}
