import Foundation
import TertiaCore
import UserNotifications

public struct UserNotificationReminderScheduler: ReminderScheduler, Sendable {
    public static let live = UserNotificationReminderScheduler()

    public static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public init() {}

    public func sync(reminders: [ClassReminder], requestPermission: Bool, now: Date) async -> ReminderSyncStatus {
        guard Self.isAppBundle else {
            return .unavailable("Notifications require running inside Tertia.app.")
        }
        let active = reminders.filter { $0.fireAt > now }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            if active.isEmpty { return .scheduled }
            guard requestPermission else { return .permissionPending }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if !granted {
                await removePendingTertiaNotifications(on: center)
                return .permissionDenied
            }
        case .denied:
            await removePendingTertiaNotifications(on: center)
            return .permissionDenied
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }

        let desiredById = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(ClassReminder.notificationPrefix) }
        var toRemove: [String] = []
        var unchanged = Set<String>()
        for req in pending {
            guard let target = desiredById[req.identifier],
                  let cal = req.trigger as? UNCalendarNotificationTrigger,
                  let nextDate = cal.nextTriggerDate(),
                  abs(nextDate.timeIntervalSince(target.fireAt)) < 1.0
            else {
                toRemove.append(req.identifier)
                continue
            }
            unchanged.insert(req.identifier)
        }
        if !toRemove.isEmpty { center.removePendingNotificationRequests(withIdentifiers: toRemove) }

        for reminder in active where !unchanged.contains(reminder.id) {
            let content = UNMutableNotificationContent()
            content.title = reminder.notificationTitle
            content.subtitle = reminder.notificationSubtitle
            content.body = reminder.notificationBody
            content.sound = .default
            content.userInfo = ["clubId": reminder.clubId, "date": reminder.date, "classId": reminder.classId]

            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireAt)
            comps.calendar = cal
            comps.timeZone = cal.timeZone

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let req = UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
            try? await center.add(req)
        }
        return .scheduled
    }

    private func removePendingTertiaNotifications(on center: UNUserNotificationCenter) async {
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(ClassReminder.notificationPrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }
}

final class ReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let onActivate: @MainActor @Sendable (Int, String) -> Void

    init(onActivate: @escaping @MainActor @Sendable (Int, String) -> Void) {
        self.onActivate = onActivate
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let clubId = info["clubId"] as? Int, let date = info["date"] as? String else { return }
        await onActivate(clubId, date)
    }
}
