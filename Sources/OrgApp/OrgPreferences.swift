import Foundation
import OrgCore
import OrgPresentation

/// The Org settings `config.toml` holds, read from user defaults with the file's fallbacks, for
/// both apps.
public enum OrgPreferences {
    public static let defaultTodoKeywords = "TODO(t) PROJ(p) LOOP(r) STRT(s) WAIT(w) HOLD(h) IDEA(i) | DONE(d) KILL(k)"

    /// TODO keywords for files without `#+TODO`, and alphabetical lists.
    public static func orgSettings(_ defaults: UserDefaults = .standard) -> OrgSettings {
        let line = defaults.string(forKey: "todoKeywords") ?? defaultTodoKeywords
        var settings = OrgSettings.default.withTodoKeywords(line) ?? .default
        settings.listAllowAlphabetical = bool("alphabeticalLists", defaults)
        settings.propertyInheritance = .init(string("propertyInheritance", defaults))
        settings.deadlineWarningDays = integer("deadlineWarningDays", defaults)
        settings.tagInheritance = .init(string("tagInheritance", defaults))
        settings.tagsExcludedFromInheritance = Set(string("tagsExcludedFromInheritance", defaults).split(whereSeparator: \.isWhitespace).map(String.init))
        return settings
    }

    /// The editing options, as the Mac's Settings apply them.
    /// `org-export-default-language`.
    public static func exportLanguage(_ defaults: UserDefaults = .standard) -> String { string("exportLanguage", defaults).nonEmpty ?? "en" }

    public static func options(_ defaults: UserDefaults = .standard) -> EditingOptions {
        var options = EditingOptions(
            tagsColumn: integer("tagsColumn", defaults), insertHeadingRespectContent: bool("headingAfterSubtree", defaults),
            metaReturnMaySplitLine: bool("splitLine", defaults),
            listAllowAlphabetical: bool("alphabeticalLists", defaults), fillColumn: integer("fillColumn", defaults),
            hideEmphasisMarkers: bool("hiddenMarkers", defaults), prettyEntities: bool("prettyEntities", defaults), subSuperscriptsNeedBraces: true,
            logDone: LogHow(rawValue: string("logDone", defaults)), logIntoDrawer: string("logIntoDrawer", defaults).nonEmpty,
            hideDrawerStartup: bool("hideDrawerStartup", defaults), hideBlockStartup: bool("hideBlockStartup", defaults),
            logReschedule: LogHow(rawValue: string("logReschedule", defaults)), logRedeadline: LogHow(rawValue: string("logRedeadline", defaults)),
            useSpeedCommands: bool("useSpeedCommands", defaults), startupWithInlineImages: bool("startupWithInlineImages", defaults),
            startupIndented: bool("startupIndented", defaults), hideLeadingStars: bool("hideLeadingStars", defaults),
            startupAlignAllTables: bool("startupAlignAllTables", defaults), startupTruncated: bool("startupTruncated", defaults),
            spellCheck: bool("spellCheck", defaults)
        )
        options.electricPair = bool("electricPair", defaults)
        options.autoFill = bool("autoFill", defaults)
        options.startupWithLatexPreview = bool("startupWithLatexPreview", defaults)
        options.remoteInlineImages = string("remoteInlineImages", defaults)
        options.enforceTodoDependencies = bool("enforceTodoDependencies", defaults)
        options.enforceTodoCheckboxDependencies = bool("enforceTodoCheckboxDependencies", defaults)
        options.archiveLocation = string("archiveLocation", defaults).nonEmpty
        options.exportLanguage = exportLanguage(defaults)
        options.clockIntoDrawer = string("clockIntoDrawer", defaults).nonEmpty
        options.tagAlist = string("tagAlist", defaults).nonEmpty
        options.clockRoundingMinutes = integer("clockRoundingMinutes", defaults)
        options.clockOutRemoveZeroTimeClocks = bool("clockRemoveZeroTime", defaults)
        options.clockInSwitchToState = string("clockInSwitchToState", defaults).nonEmpty
        options.timerFormat = string("timerFormat", defaults).contains("%s") ? string("timerFormat", defaults) : "%s "
        options.timerDefault = string("timerDefault", defaults).nonEmpty ?? "0"
        let templates = UserConfig.structureTemplates(defaults)
        options.structureTemplates = templates.isEmpty ? nil : StructureTemplate.merged(templates)
        options.trackOrderedPropertyWithTag = switch string("trackOrderedTag", defaults) {
        case "", "nil": nil
        case "t": "ORDERED"
        case let tag: tag
        }
        return options
    }

    /// `colors` with the type settings of `[theme]`: font, size, line spacing, heading step.
    public static func theme(_ colors: ThemeSpec, _ defaults: UserDefaults = .standard) -> ThemeSpec {
        var spec = colors
        spec.font = string("themeFont", defaults)
        spec.fontSize = integer("themeFontSize", defaults)
        spec.lineSpacing = integer("themeLineSpacing", defaults)
        spec.headingSizeStep = integer("themeHeadingStep", defaults)
        return spec
    }

    /// `show-markup`: link brackets and emphasis markers shown.
    public static func showMarkup(_ defaults: UserDefaults = .standard) -> Bool { bool("showMarkup", defaults) }

    public static func agendaSpan(_ defaults: UserDefaults = .standard) -> Int { integer("agendaSpan", defaults) }
    public static func agendaStartOffset(_ defaults: UserDefaults = .standard) -> Int { integer("agendaStartOffset", defaults) }
    /// `org-agenda-start-on-weekday`: 0 is Sunday; nil for `nil`.
    public static func agendaStartOnWeekday(_ defaults: UserDefaults = .standard) -> Int? { Int(string("agendaStartOnWeekday", defaults)) }
    /// `org-clock-out-when-done`: nil when marking an entry done doesn't clock out, an empty
    /// set for any done keyword, else the keywords that do.
    public static func clockOutWhenDone(_ defaults: UserDefaults = .standard) -> Set<String>? {
        let words = string("clockOutWhenDone", defaults).split(whereSeparator: \.isWhitespace).map(String.init)
        if words == ["nil"] { return nil }
        return words == ["t"] || words.isEmpty ? [] : Set(words)
    }
    public static func agendaSubfolders(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSubfolders", defaults) }
    /// `org-agenda-show-all-dates`: days without entries show.
    public static func agendaShowAllDates(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaShowAllDates", defaults) }
    public static func agendaSkipScheduledIfDone(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSkipScheduledIfDone", defaults) }
    public static func habitsOnlyForToday(_ defaults: UserDefaults = .standard) -> Bool { bool("habitsOnlyForToday", defaults) }
    public static func agendaSkipDeadlineIfDone(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSkipDeadlineIfDone", defaults) }
    public static func agendaSearchAlwaysBoolean(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSearchAlwaysBoolean", defaults) }
    public static func agendaSearchForceFullWords(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSearchForceFullWords", defaults) }
    /// `options` with the deadline warning, skip-if-done, search and blocked-entry settings.
    public static func agendaOptions(_ options: AgendaOptions, _ defaults: UserDefaults = .standard) -> AgendaOptions {
        var options = options
        options.deadlineWarningDays = integer("deadlineWarningDays", defaults)
        options.skipScheduledIfDone = agendaSkipScheduledIfDone(defaults)
        options.skipDeadlineIfDone = agendaSkipDeadlineIfDone(defaults)
        options.habitsOnlyForToday = habitsOnlyForToday(defaults)
        options.searchAlwaysBoolean = agendaSearchAlwaysBoolean(defaults)
        options.searchForceFullWords = agendaSearchForceFullWords(defaults)
        options.enforceTodoDependencies = bool("enforceTodoDependencies", defaults)
        options.enforceTodoCheckboxDependencies = bool("enforceTodoCheckboxDependencies", defaults)
        options.dimBlockedTasks = AgendaOptions.DimBlocked(rawValue: string("agendaDimBlockedTasks", defaults)) ?? .dim
        options.logItems = Set(string("agendaLogModeItems", defaults).split(whereSeparator: \.isWhitespace).map(String.init))
        options.todoIgnoreWithDate = bool("agendaTodoIgnoreWithDate", defaults)
        options.todoIgnoreScheduled = AgendaOptions.TodoIgnore(string("agendaTodoIgnoreScheduled", defaults)) ?? .off
        options.todoIgnoreDeadlines = AgendaOptions.TodoIgnore(string("agendaTodoIgnoreDeadlines", defaults), deadlines: true) ?? .off
        options.todoIgnoreTimestamp = AgendaOptions.TodoIgnore(string("agendaTodoIgnoreTimestamp", defaults)) ?? .off
        options.tagsTodoHonorIgnoreOptions = bool("agendaTagsTodoHonorIgnore", defaults)
        for (view, key) in [("agenda", "agendaPrefixAgenda"), ("todo", "agendaPrefixTodo"), ("tags", "agendaPrefixTags")] {
            options.prefixFormat[view] = string(key, defaults)
        }
        for (view, key) in [("agenda", "agendaSortAgenda"), ("todo", "agendaSortTodo"), ("tags", "agendaSortTags"), ("search", "agendaSortSearch")] {
            options.sortingStrategy[view] = sortingStrategy(string(key, defaults))
        }
        options.useTimeGrid = bool("agendaUseTimeGrid", defaults)
        options.showCurrentTimeInGrid = bool("agendaShowCurrentTime", defaults)
        options.gridWhen = Set(string("agendaTimeGridWhen", defaults).split(whereSeparator: \.isWhitespace).map(String.init))
        options.gridTimes = string("agendaTimeGridTimes", defaults).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        options.stuckProjects = stuckProjects(defaults)
        options.sortNotimeIsLate = bool("agendaSortNotimeIsLate", defaults)
        options.sortNoeffortIsHigh = bool("agendaSortNoeffortIsHigh", defaults)
        return options
    }
    /// `org-agenda-files`, one entry per line.
    public static func agendaFiles(_ defaults: UserDefaults = .standard) -> [String] {
        string("agendaFiles", defaults).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// `org-refile-targets`, `org-refile-use-outline-path` and
    /// `org-refile-allow-creating-parent-nodes`; targets that can't be read are orgstar's default.
    public static func refileSettings(_ defaults: UserDefaults = .standard) -> RefileSettings {
        let targets = (try? RefileSettings.parseTargets(string("refileTargets", defaults)).get()) ?? RefileSettings.workspaceTargets
        return RefileSettings(targets: targets, outlinePath: RefileSettings.OutlinePath(rawValue: string("refileUseOutlinePath", defaults)) ?? .file,
                              creating: RefileSettings.Creating(rawValue: string("refileAllowCreatingParentNodes", defaults)) ?? .no)
    }
    /// `org-icalendar-use-deadline`, `-use-scheduled` and `-include-todo`; the owner is the
    /// user's full name.
    public static func icalendarOptions(_ defaults: UserDefaults = .standard) -> ICalendarOptions {
        var options = ICalendarOptions()
        options.useDeadline = words(string("icalendarUseDeadline", defaults))
        options.useScheduled = words(string("icalendarUseScheduled", defaults))
        options.includeTodo = switch string("icalendarIncludeTodo", defaults).trimmingCharacters(in: .whitespaces) {
        case "", "nil": .none
        case "t": .unfinished
        case "all": .all
        case "unblocked": .unblocked
        case let list: .keywords(words(list))
        }
        options.userFullName = NSFullUserName()
        return options
    }
    /// `org-roam-directory`; empty for the first folder.
    public static func roamDirectory(_ defaults: UserDefaults = .standard) -> String { string("roamDirectory", defaults) }
    /// `org-roam-dailies-directory`, relative to `org-roam-directory` unless absolute.
    public static func dailiesDirectory(_ defaults: UserDefaults = .standard) -> String { string("dailiesDirectory", defaults).nonEmpty ?? "daily/" }
    /// The daily capture template's file name, head and entry.
    public static func dailiesFile(_ defaults: UserDefaults = .standard) -> String { string("dailiesFile", defaults).nonEmpty ?? "%<%Y-%m-%d>.org" }
    public static func dailiesHead(_ defaults: UserDefaults = .standard) -> String { string("dailiesHead", defaults).nonEmpty ?? "#+title: %<%Y-%m-%d>\n" }
    public static func dailiesEntry(_ defaults: UserDefaults = .standard) -> String { string("dailiesEntry", defaults).nonEmpty ?? "* %?" }
    /// `org-attach-id-dir`, relative to an org file's folder unless absolute.
    public static func attachIDDir(_ defaults: UserDefaults = .standard) -> String {
        let dir = string("attachIDDir", defaults)
        return dir.isEmpty ? "data/" : dir
    }
    /// `org-attach-use-inheritance`: nil for `selective`, else whether DIR and ID inherit.
    public static func attachUseInheritance(_ defaults: UserDefaults = .standard) -> Bool? {
        switch string("attachUseInheritance", defaults) {
        case "t": true
        case "nil": false
        default: nil
        }
    }
    /// `org-crypt-tag-matcher`, a tag.
    public static func cryptTag(_ defaults: UserDefaults = .standard) -> String {
        let tag = string("cryptTagMatcher", defaults).trimmingCharacters(in: .whitespaces)
        return tag.isEmpty ? "crypt" : tag
    }
    /// `org-icalendar-combined-agenda-file`, `~` expanded.
    public static func icalendarCombinedFile(_ defaults: UserDefaults = .standard) -> String {
        (string("icalendarCombinedAgendaFile", defaults) as NSString).expandingTildeInPath
    }
    /// `org-stuck-projects`.
    public static func stuckProjects(_ defaults: UserDefaults = .standard) -> StuckProjects {
        StuckProjects(match: string("stuckProjectsMatch", defaults), todo: words(string("stuckProjectsTodo", defaults)),
                      tags: words(string("stuckProjectsTags", defaults)), regexp: string("stuckProjectsRegexp", defaults))
    }
    /// Words separated by spaces.
    public static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    /// An `org-agenda-sorting-strategy` entry, keys separated by spaces; unknown keys are left out.
    public static func sortingStrategy(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init).filter(AgendaSort.keys.contains)
    }
    /// `calendar-events`: Calendar's events show in the agenda.
    public static func calendarEvents(_ defaults: UserDefaults = .standard) -> Bool { bool("calendarEvents", defaults) }
    /// `calendar-event-calendars`: the calendars chosen, by title or identifier; empty for all.
    public static func calendarEventCalendars(_ defaults: UserDefaults = .standard) -> [String] {
        string("calendarEventCalendars", defaults).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// `agenda-reminders`: Reminders' incomplete reminders show in the agenda.
    public static func agendaReminders(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaReminders", defaults) }
    /// `agenda-reminder-lists`: the lists chosen, by title or identifier; empty for all.
    public static func agendaReminderLists(_ defaults: UserDefaults = .standard) -> [String] {
        string("agendaReminderLists", defaults).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    public static func reminders(_ defaults: UserDefaults = .standard) -> Bool { bool("reminders", defaults) }
    /// `appt-message-warning-time`, in minutes.
    public static func reminderLead(_ defaults: UserDefaults = .standard) -> Int { integer("reminderLead", defaults) }
    /// `org-clock-idle-time` in minutes; 0 is nil (never).
    public static func clockIdleTime(_ defaults: UserDefaults = .standard) -> Int { integer("clockIdleTime", defaults) }
    /// `org-clock-history-length`.
    public static func clockHistoryLength(_ defaults: UserDefaults = .standard) -> Int { integer("clockHistoryLength", defaults) }

    private static func fallback(_ key: String) -> TOML.Value? {
        UserConfig.settings.first { $0.defaultsKey == key }?.fallback
    }

    private static func bool(_ key: String, _ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback(key)?.bool ?? false
    }

    private static func string(_ key: String, _ defaults: UserDefaults) -> String {
        defaults.string(forKey: key) ?? fallback(key)?.string ?? ""
    }

    /// Integers, and day offsets stored as integers with a string such as `"+0d"` as the fallback.
    private static func integer(_ key: String, _ defaults: UserDefaults) -> Int {
        if let value = defaults.object(forKey: key) as? Int { return value }
        switch fallback(key) {
        case .integer(let value)?: return value
        case .string(let text)?: return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "+d"))) ?? 0
        default: return 0
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
