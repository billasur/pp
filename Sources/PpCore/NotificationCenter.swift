import Foundation
import UserNotifications

public final class SystemNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    public static let shared = SystemNotificationScheduler()
    private let center = UNUserNotificationCenter.current()

    public init() {}

    public func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    public func requestAuthorization() async throws -> Bool {
        return try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func add(descriptor: NotificationRequestDescriptor) async throws {
        let content = UNMutableNotificationContent()
        content.title = descriptor.title
        content.body = descriptor.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger: UNNotificationTrigger?
        if let targetDate = descriptor.targetDate {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: targetDate)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else if let interval = descriptor.timeInterval {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        } else {
            trigger = nil
        }

        let request = UNNotificationRequest(identifier: descriptor.identifier, content: content, trigger: trigger)
        try await center.add(request)
    }

    public func pendingRequests() async -> [NotificationRequestDescriptor] {
        let requests = await center.pendingNotificationRequests()
        return requests.map { req in
            var targetDate: Date? = nil
            var interval: TimeInterval? = nil
            if let calTrigger = req.trigger as? UNCalendarNotificationTrigger {
                targetDate = calTrigger.nextTriggerDate()
            } else if let timeTrigger = req.trigger as? UNTimeIntervalNotificationTrigger {
                interval = timeTrigger.timeInterval
            }
            return NotificationRequestDescriptor(
                identifier: req.identifier,
                title: req.content.title,
                body: req.content.body,
                targetDate: targetDate,
                timeInterval: interval
            )
        }
    }

    public func removePendingRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Delegate that ensures notifications present alerts and sounds while pp is running in foreground/background.
public final class PpNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = PpNotificationCenterDelegate()

    public var onAlarmAction: ((String) -> Void)?
    public var onAlarmPresent: ((UNNotification) -> Void)?

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        onAlarmPresent?(notification)
        return [.banner, .sound, .list]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionID = response.actionIdentifier
        onAlarmAction?(actionID)
    }
}
