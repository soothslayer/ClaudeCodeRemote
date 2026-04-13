import UserNotifications
import UIKit

final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    // Request notification permission and register for remote notifications
    @MainActor
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // Show a local notification (used when app is backgrounded during background fetch)
    func showLocalNotification(title: String, body: String, userInfo: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .defaultCritical
        content.userInfo = userInfo
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // Deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
