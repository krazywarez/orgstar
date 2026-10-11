import Foundation
import Observation
import OrgCore
@preconcurrency import UserNotifications

/// The app's org-timer, which commands get in `EditingOptions.timer` and change through
/// `Effect.timer`. A countdown ends with a notification and `onDone`.
@MainActor @Observable
public final class TimerModel {
    public static let shared = TimerModel()

    public private(set) var timer: OrgTimer?
    /// The countdown's message when it ends, for the echo area.
    @ObservationIgnored public var onDone: ((String) -> Void)?
    @ObservationIgnored private var countdown: Task<Void, Never>?
    static let notification = "sh.krz.orgstar.org-timer"

    public init() {}

    public func set(_ new: OrgTimer?) {
        timer = new
        countdown?.cancel()
        countdown = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notification])
        guard let new, new.isCountdown, new.paused == nil else { return }
        let left = max(0, new.start.timeIntervalSinceNow)
        countdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled, let self, self.timer == new else { return }
            self.timer = nil
            self.onDone?(new.doneMessage)
        }
        // The notification shows when orgstar isn't in front, as `org-notify` does.
        let content = UNMutableNotificationContent()
        content.title = new.doneMessage
        content.sound = .default
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: Self.notification, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, left), repeats: false)))
        }
    }
}
