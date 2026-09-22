import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter for done/failed notifications.
/// macOS allows non-sandboxed, ad-hoc-signed apps to post user notifications
/// once authorized — no entitlement required.
final class Notifier {
    static let shared = Notifier()
    private var authorized = false

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    func post(title: String, body: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}