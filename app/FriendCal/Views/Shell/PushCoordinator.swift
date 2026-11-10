import UIKit
import UserNotifications
import FriendCalCore

extension Notification.Name {
    /// APNs issued (or re-issued) this device's token; read it from `PushCoordinator.deviceToken`.
    static let friendCalDeviceToken = Notification.Name("FriendCalDeviceToken")
    /// A push was tapped; take it with `PushCoordinator.takePendingRoute()`.
    static let friendCalPushTapped = Notification.Name("FriendCalPushTapped")
    /// A push arrived while the app was open.
    static let friendCalPushArrived = Notification.Name("FriendCalPushArrived")
}

/// The app's only contact with APNs and the notification center.
///
///     launch ──> delegate set ──────────────────────────────────────────────┐
///     SocialSession asks ──> request() ──> register() ──> token ──> .friendCalDeviceToken ──> store.registerDevice
///     push tapped ──> PushRoute.parse ──> pendingRoute ──> .friendCalPushTapped ──> shell routes + acknowledges
///
/// A tap can arrive before there is a shell to route it (a cold launch from the notification, or a
/// launch that lands on the sign-in screen), so the route is HELD here until someone takes it. The
/// posted notification only says "look"; whoever takes the route owns it, exactly once.
///
/// It never asks for permission by itself. `SocialSession` decides when (after the first poke
/// someone sends, or the Pokes tab's "Turn on"), and never on demo data.
@MainActor
final class PushCoordinator: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private(set) static var deviceToken: String?
    private static var pendingRoute: PushRoute?

    static func takePendingRoute() -> PushRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    static func state() async -> SocialSession.NotificationState {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .authorized
        }
    }

    /// Shows the system prompt (once; later calls answer from the saved choice) and registers on a yes.
    static func request() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { register() }
        return granted
    }

    static func register() { UIApplication.shared.registerForRemoteNotifications() }

    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: UIApplicationDelegate

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .friendCalDeviceToken, object: nil)
    }

    /// No entitlement (a fresh clone), no network, the Simulator on an older host: pokes still work
    /// in the app, they just do not arrive as pushes. Nothing to tell the person.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    // MARK: UNUserNotificationCenterDelegate

    /// In the foreground a poke still shows its banner, and the inbox re-reads right away.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in NotificationCenter.default.post(name: .friendCalPushArrived, object: nil) }
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let route = PushRoute.parse(response.notification.request.content.userInfo)
        Task { @MainActor in
            if let route {
                Self.pendingRoute = route
                NotificationCenter.default.post(name: .friendCalPushTapped, object: nil)
            }
            completionHandler()
        }
    }
}
