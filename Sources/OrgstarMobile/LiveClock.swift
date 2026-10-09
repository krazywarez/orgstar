#if os(iOS)
import ActivityKit
import AppIntents
import OrgApp

/// The running clock's Live Activity: one while a clock runs, started when it starts and
/// ended when it stops, however that happens.
@MainActor
enum LiveClock {
    nonisolated private static func isLive(_ activity: Activity<ClockActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    nonisolated private static func shows(_ activity: Activity<ClockActivityAttributes>, _ running: ClockModel.Running) -> Bool {
        activity.attributes.path == running.path && activity.attributes.start == running.start
    }

    /// Ends activities of other clocks; starts one for `running` unless it has one.
    nonisolated static func sync(_ running: ClockModel.Running?) async {
        let activities = Activity<ClockActivityAttributes>.activities.filter(isLive)
        for activity in activities where running.map({ !shows(activity, $0) }) ?? true {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard let running, !activities.contains(where: { shows($0, running) }), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = ClockActivityAttributes.ContentState(heading: running.heading, startedAt: running.startedAt)
        _ = try? Activity.request(
            attributes: ClockActivityAttributes(path: running.path, start: running.start), content: ActivityContent(state: state, staleDate: nil)
        )
    }

    /// The Clock Out button's work, in the app's process.
    static func install() {
        ClockOutIntent.handler = {
            let model = MobileModel.shared
            let path = model.clock.running?.path
            _ = model.clock.clockOut(model.session)
            if let path, model.session.dirtyPaths.contains(path) { _ = model.session.save(path) }
            await sync(model.clock.running)
        }
    }
}

/// The App Intents OrgApp declares.
struct OrgstarIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [OrgAppIntents.self] }
}
#endif
