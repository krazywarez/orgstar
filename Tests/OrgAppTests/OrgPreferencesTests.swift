import Foundation
import OrgCore
import Testing
@testable import OrgApp

struct OrgPreferencesTests {
    @Test func readsWhatConfigTomlSets() throws {
        let defaults = try #require(UserDefaults(suiteName: "orgstar-preferences-\(UUID().uuidString)"))
        // Nothing set: the file's fallbacks, which match the Mac's.
        #expect(OrgPreferences.orgSettings(defaults).todoSequences.first?.active.map(\.name) == ["TODO", "PROJ", "LOOP", "STRT", "WAIT", "HOLD", "IDEA"])
        #expect(OrgPreferences.options(defaults).logDone == nil && OrgPreferences.options(defaults).tagsColumn == -77)
        #expect(OrgPreferences.agendaSpan(defaults) == 10 && OrgPreferences.agendaStartOffset(defaults) == -3)
        #expect(OrgPreferences.reminders(defaults) && OrgPreferences.reminderLead(defaults) == 12)

        let problems = UserConfig.apply("""
            org-todo-keywords = "TODO NEXT | DONE"
            org-log-done = "time"
            org-log-into-drawer = "LOGBOOK"
            org-agenda-span = 7
            org-agenda-start-day = "-1d"
            appt-message-warning-time = 30
            [orgstar]
            reminders = false
            """, to: defaults)
        #expect(problems.isEmpty, "\(problems)")
        #expect(OrgPreferences.orgSettings(defaults).todoSequences.first?.active.map(\.name) == ["TODO", "NEXT"])
        let options = OrgPreferences.options(defaults)
        #expect(options.logDone == .time && options.logIntoDrawer == "LOGBOOK")
        #expect(OrgPreferences.agendaSpan(defaults) == 7 && OrgPreferences.agendaStartOffset(defaults) == -1)
        #expect(!OrgPreferences.reminders(defaults) && OrgPreferences.reminderLead(defaults) == 30)
    }
}
