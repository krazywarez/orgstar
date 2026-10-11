import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgApp

struct OrgPreferencesTests {
    @Test func readsWhatConfigTomlSets() throws {
        let defaults = try #require(UserDefaults(suiteName: "orgstar-preferences-\(UUID().uuidString)"))
        // Nothing set: the file's fallbacks, which match the Mac's.
        #expect(OrgPreferences.orgSettings(defaults).todoSequences.first?.active.map(\.name) == ["TODO", "PROJ", "LOOP", "STRT", "WAIT", "HOLD", "IDEA"])
        #expect(OrgPreferences.options(defaults).logDone == nil && OrgPreferences.options(defaults).tagsColumn == -77)
        #expect(OrgPreferences.agendaSpan(defaults) == 10 && OrgPreferences.agendaStartOffset(defaults) == 0)
        #expect(OrgPreferences.orgSettings(defaults).deadlineWarningDays == 14)
        #expect(OrgPreferences.agendaStartOnWeekday(defaults) == 1)
        #expect(OrgPreferences.options(defaults).trackOrderedPropertyWithTag == nil)
        #expect(OrgPreferences.options(defaults).archiveLocation == "%s_archive::")
        #expect(OrgPreferences.agendaOptions(AgendaOptions(), defaults).deadlineWarningDays == 14)
        #expect(OrgPreferences.reminders(defaults) && OrgPreferences.reminderLead(defaults) == 12)
        let fallbacks = OrgPreferences.options(defaults)
        #expect(!fallbacks.metaReturnMaySplitLine && fallbacks.hideEmphasisMarkers && fallbacks.prettyEntities && fallbacks.subSuperscriptsNeedBraces)
        #expect(fallbacks.startupIndented && !fallbacks.spellCheck && fallbacks.hideDrawerStartup && !fallbacks.hideBlockStartup)

        let problems = UserConfig.apply("""
            org-todo-keywords = "TODO NEXT | DONE"
            org-log-done = "time"
            org-log-into-drawer = "LOGBOOK"
            org-agenda-span = 7
            org-agenda-start-day = "-1d"
            appt-message-warning-time = 30
            org-deadline-warning-days = 5
            org-agenda-start-on-weekday = "nil"
            org-track-ordered-property-with-tag = "t"
            org-archive-location = "~/org/archive.org::* %s"
            org-M-RET-may-split-line = true
            org-hide-emphasis-markers = false
            org-pretty-entities = false
            [orgstar]
            reminders = false
            """, to: defaults)
        #expect(problems.isEmpty, "\(problems)")
        #expect(OrgPreferences.orgSettings(defaults).todoSequences.first?.active.map(\.name) == ["TODO", "NEXT"])
        let options = OrgPreferences.options(defaults)
        #expect(options.logDone == .time && options.logIntoDrawer == "LOGBOOK")
        #expect(options.metaReturnMaySplitLine && !options.hideEmphasisMarkers && !options.prettyEntities)
        #expect(OrgPreferences.agendaSpan(defaults) == 7 && OrgPreferences.agendaStartOffset(defaults) == -1)
        #expect(OrgPreferences.orgSettings(defaults).deadlineWarningDays == 5)
        #expect(OrgPreferences.agendaStartOnWeekday(defaults) == nil)
        #expect(OrgPreferences.options(defaults).trackOrderedPropertyWithTag == "ORDERED")
        #expect(OrgPreferences.options(defaults).archiveLocation == "~/org/archive.org::* %s")
        #expect(OrgPreferences.agendaOptions(AgendaOptions(), defaults).deadlineWarningDays == 5)
        #expect(!OrgPreferences.reminders(defaults) && OrgPreferences.reminderLead(defaults) == 30)
        #expect(UserConfig.apply("org-agenda-start-on-weekday = \"0\"", to: defaults).isEmpty)
        #expect(OrgPreferences.agendaStartOnWeekday(defaults) == 0)
        #expect(!UserConfig.apply("org-agenda-start-on-weekday = \"7\"", to: defaults).isEmpty)
    }

    @Test func themeTypeAndShowMarkup() throws {
        let defaults = try #require(UserDefaults(suiteName: "orgstar-preferences-\(UUID().uuidString)"))
        var colors = ThemeSpec.default
        colors.light["link"] = RGBA(hex: "#000001")
        let fallback = OrgPreferences.theme(colors, defaults)
        #expect(fallback.font == "" && fallback.fontSize == 13 && fallback.lineSpacing == 2 && fallback.headingSizeStep == 1)
        #expect(fallback.light["link"]?.hex == "#000001")
        #expect(!OrgPreferences.showMarkup(defaults))
        _ = UserConfig.apply("[theme]\nfont = \"Menlo\"\nfont-size = 16\nline-spacing = 4\nheading-size-step = 2\n[orgstar]\nshow-markup = true\n", to: defaults)
        let spec = OrgPreferences.theme(colors, defaults)
        #expect(spec.font == "Menlo" && spec.fontSize == 16 && spec.lineSpacing == 4 && spec.headingSizeStep == 2)
        #expect(OrgPreferences.showMarkup(defaults))
    }
}
