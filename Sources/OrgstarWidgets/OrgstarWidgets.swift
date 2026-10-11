import AppIntents
import OrgApp
import SwiftUI
import WidgetKit

/// The agenda and habits on the Home Screen and the Lock Screen, capture and the clock in
/// Control Center, and the running clock's Live Activity; on the Mac, the agenda and habits on
/// the desktop and in Notification Center.
@main
struct OrgstarWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        HabitsWidget()
        UpNextWidget()
        #if os(iOS)
        CaptureWidget()
        ClockActivityWidget()
        CaptureControl()
        ClockControl()
        #endif
    }
}

#if os(iOS)
/// The App Intents OrgApp declares: the Live Activity's Clock Out button.
struct OrgstarWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [OrgAppIntents.self] }
}
#endif
