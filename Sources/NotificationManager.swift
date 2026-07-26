import Foundation
import UserNotifications

/// Manages local push notifications for re-engagement.
/// Scheduled when the user disconnects / closes the app; cancelled when they reconnect.
final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    // MARK: - Permission

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Schedule re-engagement notifications

    /// Call this when the user disconnects from the controller.
    /// Schedules three nudge notifications at 1 hour, 1 day and 3 days out.
    func scheduleRideReminders(lastConnectedDate: Date = Date()) {
        cancelRideReminders()

        let nudges: [(TimeInterval, String, String)] = [
            (3600,        "Get back to riding 🏍️",   "Your DUNEN BB6D is waiting. Tap to check live telemetry."),
            (86400,       "It's been a day!",          "You haven't connected to your bike in 24 hours. Everything ok?"),
            (3 * 86400,   "We miss you on the road",   "It's been 3 days since your last ride. Fire up Aptum Dashboard and go!"),
        ]

        for (delay, title, body) in nudges {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            let id = "ride_reminder_\(Int(delay))"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    /// Cancel all pending ride reminder notifications (call on connect).
    func cancelRideReminders() {
        let ids = ["ride_reminder_3600", "ride_reminder_86400", "ride_reminder_259200"]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}
