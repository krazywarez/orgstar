import AppIntents
import OrgApp
import SwiftUI
import WidgetKit

/// The agenda and habits on the Home Screen and the Lock Screen, capture and the clock in
/// Control Center, and the running clock's Live Activity.
@main
struct OrgstarWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        HabitsWidget()
        UpNextWidget()
        CaptureWidget()
        ClockActivityWidget()
        CaptureControl()
        ClockControl()
    }
}

/// The App Intents OrgApp declares: the Live Activity's Clock Out button.
struct OrgstarWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [OrgAppIntents.self] }
}
