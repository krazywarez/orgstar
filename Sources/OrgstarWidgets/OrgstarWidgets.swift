import AppIntents
import OrgApp
import SwiftUI
import WidgetKit

/// The agenda on the Home Screen and the Lock Screen, and the running clock's Live Activity.
@main
struct OrgstarWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        UpNextWidget()
        ClockActivityWidget()
    }
}

/// The App Intents OrgApp declares: the Live Activity's Clock Out button.
struct OrgstarWidgetIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [OrgAppIntents.self] }
}
