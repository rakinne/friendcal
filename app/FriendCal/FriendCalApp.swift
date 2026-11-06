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
            AppTabView()
        }
    }
}
