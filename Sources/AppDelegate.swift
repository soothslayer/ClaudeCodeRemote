import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Enable background fetch
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        return true
    }

    // Show notification as banner when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.sound, .badge])
    }

    // Handle notification tap (app was in background)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let responseText = userInfo["response"] as? String {
            NotificationCenter.default.post(
                name: .claudeResponseReceived,
                object: nil,
                userInfo: ["response": responseText]
            )
        }
        completionHandler()
    }

    // Background fetch — check for any pending response the server held
    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let api = APIService()
            do {
                let info = try await api.sessionInfo()
                if let pending = info.pendingResponse {
                    NotificationManager.shared.showLocalNotification(
                        title: "Claude Code replied",
                        body: pending,
                        userInfo: ["response": pending]
                    )
                    completionHandler(.newData)
                } else {
                    completionHandler(.noData)
                }
            } catch {
                completionHandler(.failed)
            }
        }
    }
}

extension Notification.Name {
    static let claudeResponseReceived = Notification.Name("claudeResponseReceived")
}
