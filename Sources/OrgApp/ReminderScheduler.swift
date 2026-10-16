import Foundation
import Observation
import OrgCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Where reminders are delivered: the system's notification center, or a fake in tests.
public protocol ReminderCenter: Sendable {
    /// Whether notifications may be shown, asking the user the first time.
    func authorize() async -> Bool
    /// IDs of pending requests.
    func pendingIDs() async -> [String]
    /// IDs of notifications shown and still in Notification Center.
    func deliveredIDs() async -> [String]
    func add(_ reminder: Reminder) async throws
    func remove(_ ids: [String])
}

/// Keeps the pending notifications equal to the reminders the agenda gives.
@MainActor
@Observable
public final class ReminderScheduler {
    /// The last event a reminder is set for, so the agenda can say how far ahead they go.
    public private(set) var scheduledThrough: Date?
    /// False when the user turned notifications off for the app.
    public private(set) var isAuthorized = true

    private let center: ReminderCenter
    /// What this run set; one no longer pending has fired and isn't set again.
    private var scheduled: Set<String> = []

    public init(center: ReminderCenter) {
        self.center = center
    }

    /// Adds reminders that are new, removes ours that no longer apply, leaves the rest.
    public func reconcile(_ reminders: [Reminder]) async {
        isAuthorized = await center.authorize()
        guard isAuthorized else {
            scheduledThrough = nil
            return
        }
        let wanted = Set(reminders.map(\.id))
        let pending = Set(await center.pendingIDs().filter { $0.hasPrefix("orgstar.") })
        let stale = pending.subtracting(wanted)
        if !stale.isEmpty { center.remove(Array(stale)) }
        scheduled.subtract(stale)
        // A reminder whose warning time has passed fires at once; once shown, it stays shown.
        let delivered = Set(await center.deliveredIDs())
        for reminder in reminders where !pending.contains(reminder.id) && !scheduled.contains(reminder.id) && !delivered.contains(reminder.id) {
            try? await center.add(reminder)
            scheduled.insert(reminder.id)
        }
        scheduledThrough = reminders.map(\.eventDate).max()
    }

    /// Removes every reminder, when the user turns them off.
    public func clear() async {
        let ours = await center.pendingIDs().filter { $0.hasPrefix("orgstar.") }
        if !ours.isEmpty { center.remove(ours) }
        scheduled = []
        scheduledThrough = nil
    }
}

#if canImport(UserNotifications)
/// `UNUserNotificationCenter`. Only usable from an app bundle.
public struct SystemReminderCenter: ReminderCenter {
    public init() {}

    /// The system center needs a bundle identifier; a bare debug binary has none.
    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    public func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            // iOS shows the overdue count on the icon.
            #if os(iOS)
            let options: UNAuthorizationOptions = [.alert, .sound, .badge]
            #else
            let options: UNAuthorizationOptions = [.alert, .sound]
            #endif
            return (try? await center.requestAuthorization(options: options)) ?? false
        default: return false
        }
    }

    public func pendingIDs() async -> [String] {
        await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier)
    }

    public func add(_ reminder: Reminder) async throws {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.userInfo = ["path": reminder.path, "offset": reminder.offset]
        if let folder = reminder.folder { content.filterCriteria = folder }
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
    }

    public func deliveredIDs() async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
    }

    public func remove(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}
#endif
