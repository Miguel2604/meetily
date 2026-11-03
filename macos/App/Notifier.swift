import AppKit
import UserNotifications

/// Local notifications for recording started/stopped and summary ready. Clicking one that names a meeting opens it.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var openMeeting: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ title: String, _ body: String, meetingID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let meetingID { content.userInfo = ["meetingID": meetingID] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            // Users who skipped onboarding (imported from the Tauri app) are asked on the first notification.
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            }
            try? await center.add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["meetingID"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            openMeeting?(id)
        }
    }
}
