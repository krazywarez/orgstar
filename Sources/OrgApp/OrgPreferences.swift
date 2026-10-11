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
        options.enforceTodoDependencies = bool("enforceTodoDependencies", defaults)
        options.enforceTodoCheckboxDependencies = bool("enforceTodoCheckboxDependencies", defaults)
        options.archiveLocation = string("archiveLocation", defaults).nonEmpty
        options.clockIntoDrawer = string("clockIntoDrawer", defaults).nonEmpty
        options.tagAlist = string("tagAlist", defaults).nonEmpty
        options.clockRoundingMinutes = integer("clockRoundingMinutes", defaults)
        options.clockOutRemoveZeroTimeClocks = bool("clockRemoveZeroTime", defaults)
        options.clockInSwitchToState = string("clockInSwitchToState", defaults).nonEmpty
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
    public static func agendaSkipDeadlineIfDone(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSkipDeadlineIfDone", defaults) }
    public static func agendaSearchAlwaysBoolean(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSearchAlwaysBoolean", defaults) }
    public static func agendaSearchForceFullWords(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSearchForceFullWords", defaults) }
    /// `options` with the deadline warning, skip-if-done, search and blocked-entry settings.
    public static func agendaOptions(_ options: AgendaOptions, _ defaults: UserDefaults = .standard) -> AgendaOptions {
        var options = options
        options.deadlineWarningDays = integer("deadlineWarningDays", defaults)
        options.skipScheduledIfDone = agendaSkipScheduledIfDone(defaults)
        options.skipDeadlineIfDone = agendaSkipDeadlineIfDone(defaults)
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
        return options
    }
    /// `calendar-events`: Calendar's events show in the agenda.
    public static func calendarEvents(_ defaults: UserDefaults = .standard) -> Bool { bool("calendarEvents", defaults) }
    /// `calendar-event-calendars`: the calendars chosen, by title or identifier; empty for all.
    public static func calendarEventCalendars(_ defaults: UserDefaults = .standard) -> [String] {
        string("calendarEventCalendars", defaults).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
