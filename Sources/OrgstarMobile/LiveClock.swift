#if os(iOS)
import ActivityKit
import AppIntents
import OrgApp
import WidgetKit

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

    /// The clock control's state: the running clock, and the entry Clock In Last would take.
    static func publish(_ clock: ClockModel) {
        let snapshot = ClockSnapshot(running: clock.running?.heading, startedAt: clock.running?.startedAt, last: clock.history.first?.title)
        if (try? snapshot.write()) == true { ControlCenter.shared.reloadControls(ofKind: "sh.krz.orgstar.clock-control") }
    }

    /// The Clock Out button's work, in the app's process, and the capture and clock controls'.
    static func install() {
        ClockOutIntent.handler = clockOut
        ClockToggleIntent.handler = { on in
            guard on else { return await clockOut() }
            // Asks in the app if a dangling clock needs resolving.
            let model = MobileModel.shared
            guard let workspace = model.workspace else { return }
            let paths = workspace.files.filter { $0.kind == .org }.map(\.path)
            _ = await model.clock.clockIn(model.session, target: .last, paths: paths, ask: model.clockPrompts.ask)
            for path in model.session.dirtyPaths { _ = model.session.save(path) }
            await sync(model.clock.running)
            publish(model.clock)
        }
        OpenCaptureIntent.handler = { template in
            MobileModel.shared.captureRequest = CaptureRequest(template: template)
        }
    }

    private static func clockOut() async {
        let model = MobileModel.shared
        let path = model.clock.running?.path
        _ = model.clock.clockOut(model.session)
        if let path, model.session.dirtyPaths.contains(path) { _ = model.session.save(path) }
        await sync(model.clock.running)
        publish(model.clock)
    }
}

/// The App Intents OrgApp declares.
struct OrgstarIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [OrgAppIntents.self] }
}
#endif
