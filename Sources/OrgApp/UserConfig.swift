import Foundation
import OrgCore
import OrgPresentation
import OrgWorkspace

/// The configuration folder (`$XDG_CONFIG_HOME/orgstar`, else `~/.config/orgstar`) and
/// `config.toml` in it: every setting of the Settings window as text, to edit, keep in a
/// dotfiles repository and share. The file is the source of truth: Settings writes its changes
/// into it, keeping comments and order, and edits to it apply while the app runs.
public enum UserConfig {
    /// A folder chosen in the app (on iOS, a synced copy of the Mac's), used over the default.
    nonisolated(unsafe) public static var directoryOverride: URL?

    public static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["ORGSTAR_CONFIG_DIR"] { return URL(fileURLWithPath: override) }
        // Development runs keep everything in their data folder.
        if let data = environment["ORGSTAR_DATA_DIR"] { return URL(fileURLWithPath: data) }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("orgstar")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/orgstar")
    }

    /// The theme `config.toml` (`text`) sets: its `[theme]` tables' colors over those of
    /// `theme-file` (a path relative to `folder`), over the default theme; with problems in
    /// both. Nil when `text` isn't TOML.
    public static func theme(
        config text: String, themeFile name: String?, in folder: URL,
        read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> (theme: ThemeSpec, problems: [String])? {
        guard let tables = try? TOML.parse(text) else { return nil }
        var spec = ThemeSpec.default
        var problems: [String] = []
        if let name, !name.isEmpty {
            if let themeText = read(folder.appendingPathComponent(name)) {
                do {
                    (spec, problems) = ThemeSpec.reading(try TOML.parse(themeText), file: name)
                } catch {
                    problems.append("\(name): \(error)")
                }
            } else {
                problems.append("config.toml: theme-file \(name) can't be read")
            }
        }
        let (merged, more) = ThemeSpec.reading(tables, over: spec)
        return (merged, problems + more)
    }

    /// Where earlier versions kept the configuration files.
    public static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orgstar")
    }

    /// A file of the configuration folder; one that exists only where earlier versions kept
    /// it (Application Support) is still read from there.
    public static func file(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        let legacy = legacyDirectory.appendingPathComponent(name)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path), manager.fileExists(atPath: legacy.path) { return legacy }
        return url
    }

    public static var configFile: URL { directory.appendingPathComponent("config.toml") }

    /// One setting: where it sits in the file, its user-defaults key, and how values convert.
    /// Settings Emacs has a variable for sit at the top of the file under that variable's
    /// name; the rest go in `[orgstar]`.
    public struct Setting: Sendable {
        public enum Kind: Sendable {
            case bool, integer, string
            /// A string in the file for each stored value.
            case choice([(name: String, stored: String)])
            case integerChoice([(name: String, stored: Int)])
            /// `org-agenda-start-day`: `"-3d"` in the file, -3 stored.
            case dayOffset
        }

        public let section: String
        public let key: String
        public let defaultsKey: String
        public let kind: Kind
        public let fallback: TOML.Value
        public let comment: String
        /// Where earlier versions of the file kept it, `section.key`.
        public let legacy: String

        public var path: String { section.isEmpty ? key : section + "." + key }
    }

    public static let settings: [Setting] = [
        Setting(section: "", key: "fill-column", defaultsKey: "fillColumn", kind: .integer, fallback: .integer(80),
                comment: "M-q fills to this column", legacy: "editor.fill-column"),
        Setting(section: "", key: "org-tags-column", defaultsKey: "tagsColumn", kind: .integer, fallback: .integer(-77),
                comment: "negative: tags end at that column; 0: one space before them", legacy: "editor.tags-column"),
        Setting(section: "", key: "org-insert-heading-respect-content", defaultsKey: "headingAfterSubtree", kind: .bool, fallback: .bool(true),
                comment: "M-RET adds the new heading after the subtree", legacy: "editor.insert-heading-respect-content"),
        Setting(section: "", key: "org-M-RET-may-split-line", defaultsKey: "splitLine", kind: .bool, fallback: .bool(false),
                comment: "M-RET splits the line at the caret", legacy: "editor.meta-return-may-split-line"),
        Setting(section: "", key: "org-use-property-inheritance", defaultsKey: "propertyInheritance", kind: .string, fallback: .string("nil"),
                comment: "nil, t, or property names that inherit, separated by spaces, such as \"STYLE\"", legacy: ""),
        Setting(section: "", key: "org-list-allow-alphabetical", defaultsKey: "alphabeticalLists", kind: .bool, fallback: .bool(true),
                comment: "lists can use a. b. c.", legacy: "editor.list-allow-alphabetical"),
        Setting(section: "", key: "org-hide-emphasis-markers", defaultsKey: "hiddenMarkers", kind: .bool, fallback: .bool(true),
                comment: "hide *bold* and =code= markers when markup is hidden", legacy: "editor.hide-emphasis-markers"),
        Setting(section: "", key: "org-pretty-entities", defaultsKey: "prettyEntities", kind: .bool, fallback: .bool(true),
                comment: "\\alpha shows as α and x_{1} is lowered when markup is hidden", legacy: "editor.pretty-entities"),
        Setting(section: "", key: "org-todo-keywords", defaultsKey: "todoKeywords", kind: .string, fallback: .string("TODO(t) PROJ(p) LOOP(r) STRT(s) WAIT(w) HOLD(h) IDEA(i) | DONE(d) KILL(k)"),
                comment: "for files without #+TODO, in #+TODO syntax, one sequence per line (\\n); keys in parentheses turn on fast selection; read at launch", legacy: "editor.todo-keywords"),
        Setting(section: "", key: "org-log-done", defaultsKey: "logDone", kind: .choice([("nil", "nil"), ("time", "time"), ("note", "note")]),
                fallback: .string("nil"), comment: "nil, time (CLOSED when done) or note (CLOSED and a note)", legacy: ""),
        Setting(section: "", key: "org-log-reschedule", defaultsKey: "logReschedule", kind: .choice([("nil", "nil"), ("time", "time"), ("note", "note")]),
                fallback: .string("nil"), comment: "nil, time or note: log changing or removing a SCHEDULED date", legacy: ""),
        Setting(section: "", key: "org-log-redeadline", defaultsKey: "logRedeadline", kind: .choice([("nil", "nil"), ("time", "time"), ("note", "note")]),
                fallback: .string("nil"), comment: "nil, time or note: log changing or removing a DEADLINE", legacy: ""),
        Setting(section: "", key: "org-log-into-drawer", defaultsKey: "logIntoDrawer", kind: .string, fallback: .string(""),
                comment: "the drawer state notes go in (\"LOGBOOK\" is Emacs's t); \"\" for none", legacy: ""),
        Setting(section: "", key: "org-enforce-todo-dependencies", defaultsKey: "enforceTodoDependencies", kind: .bool, fallback: .bool(false),
                comment: "an entry can't be done before its TODO children, or under an ORDERED parent before its earlier siblings", legacy: ""),
        Setting(section: "", key: "org-enforce-todo-checkbox-dependencies", defaultsKey: "enforceTodoCheckboxDependencies", kind: .bool, fallback: .bool(false),
                comment: "an entry can't be done while it has unchecked boxes", legacy: ""),
        Setting(section: "", key: "org-archive-location", defaultsKey: "archiveLocation", kind: .string, fallback: .string("%s_archive::"),
                comment: "where Archive Subtree moves an entry without an ARCHIVE property or #+ARCHIVE: file::heading, %s the file's name", legacy: ""),
        Setting(section: "", key: "org-use-tag-inheritance", defaultsKey: "tagInheritance", kind: .string, fallback: .string("t"),
                comment: "t, nil, tags that inherit separated by spaces, or a regexp in braces such as \"{^@}\"", legacy: ""),
        Setting(section: "", key: "org-tags-exclude-from-inheritance", defaultsKey: "tagsExcludedFromInheritance", kind: .string, fallback: .string(""),
                comment: "tags that never inherit, separated by spaces", legacy: ""),
        Setting(section: "", key: "org-tag-alist", defaultsKey: "tagAlist", kind: .string, fallback: .string(""),
                comment: "tags C-c C-q offers in files without #+TAGS, in #+TAGS syntax: \"work(w) home(h) { @office(o) @home(H) }\"", legacy: ""),
        Setting(section: "", key: "org-track-ordered-property-with-tag", defaultsKey: "trackOrderedTag", kind: .string, fallback: .string("nil"),
                comment: "nil, t (the tag ORDERED) or a tag that Toggle ORDERED Property toggles too", legacy: ""),
        Setting(section: "", key: "org-startup-indented", defaultsKey: "startupIndented", kind: .bool, fallback: .bool(true),
                comment: "indent bodies under their headings (org-indent-mode); #+STARTUP: (no)indent overrides", legacy: ""),
        Setting(section: "", key: "org-hide-leading-stars", defaultsKey: "hideLeadingStars", kind: .bool, fallback: .bool(false),
                comment: "show only a heading's last star without indentation; #+STARTUP: hidestars/showstars overrides", legacy: ""),
        Setting(section: "", key: "org-startup-align-all-tables", defaultsKey: "startupAlignAllTables", kind: .bool, fallback: .bool(false),
                comment: "align every table when a file opens; #+STARTUP: (no)align overrides", legacy: ""),
        Setting(section: "", key: "org-startup-truncated", defaultsKey: "startupTruncated", kind: .bool, fallback: .bool(false),
                comment: "truncate long lines instead of wrapping them (Emacs's default is t; Doom wraps)", legacy: ""),
        Setting(section: "", key: "spell-check", defaultsKey: "spellCheck", kind: .bool, fallback: .bool(false),
                comment: "check spelling while typing, outside code, links, dates, tags and keywords", legacy: ""),
        Setting(section: "", key: "electric-pair-mode", defaultsKey: "electricPair", kind: .bool, fallback: .bool(true),
                comment: "type brackets, <> and quotes in pairs as electric-pair-mode does (off in plain Emacs; Doom pairs with smartparens)", legacy: ""),
        Setting(section: "", key: "org-startup-with-inline-images", defaultsKey: "startupWithInlineImages", kind: .bool, fallback: .bool(false),
                comment: "show image links as images when a file opens; #+STARTUP: (no)inlineimages overrides", legacy: ""),
        Setting(section: "", key: "org-use-speed-commands", defaultsKey: "useSpeedCommands", kind: .bool, fallback: .bool(false),
                comment: "single keys at the start of a heading line run commands (n, p, t, c, …)", legacy: ""),
        Setting(section: "", key: "org-cycle-hide-drawer-startup", defaultsKey: "hideDrawerStartup", kind: .bool, fallback: .bool(true),
                comment: "fold drawers when a file opens; #+STARTUP: nohidedrawers overrides", legacy: ""),
        Setting(section: "", key: "org-cycle-hide-block-startup", defaultsKey: "hideBlockStartup", kind: .bool, fallback: .bool(false),
                comment: "fold blocks when a file opens; #+STARTUP: hideblocks overrides", legacy: ""),
        Setting(section: "", key: "display-line-numbers-type", defaultsKey: "showLineNumbers", kind: .bool, fallback: .bool(true),
                comment: "line numbers (View ▸ Show Line Numbers)", legacy: "editor.line-numbers"),
        Setting(section: "", key: "org-agenda-span", defaultsKey: "agendaSpan", kind: .integer, fallback: .integer(10),
                comment: "days the agenda shows", legacy: "agenda.span"),
        Setting(section: "", key: "org-agenda-start-day", defaultsKey: "agendaStartOffset", kind: .dayOffset, fallback: .string("+0d"),
                comment: "the agenda's first day: \"-3d\", \"+0d\"", legacy: "agenda.start-offset"),
        Setting(section: "", key: "org-deadline-warning-days", defaultsKey: "deadlineWarningDays", kind: .integer, fallback: .integer(14),
                comment: "days ahead the agenda warns about a deadline; a -Nd cookie overrides", legacy: ""),
        Setting(section: "", key: "org-agenda-start-on-weekday", defaultsKey: "agendaStartOnWeekday",
                kind: .choice([("nil", "nil")] + (0...6).map { ("\($0)", "\($0)") }), fallback: .string("1"),
                comment: "weeks start on this day, 0 Sunday to 6 Saturday, or nil for the agenda's first day", legacy: ""),
        Setting(section: "", key: "org-agenda-show-all-dates", defaultsKey: "agendaShowAllDates", kind: .bool, fallback: .bool(false),
                comment: "show days with no entries (Emacs's default is t; orgstar hides them); today always shows", legacy: ""),
        Setting(section: "", key: "org-agenda-skip-scheduled-if-done", defaultsKey: "agendaSkipScheduledIfDone", kind: .bool, fallback: .bool(false),
                comment: "leave done entries out of the agenda even on the day they are scheduled", legacy: ""),
        Setting(section: "", key: "org-agenda-skip-deadline-if-done", defaultsKey: "agendaSkipDeadlineIfDone", kind: .bool, fallback: .bool(false),
                comment: "leave done entries out of the agenda even on the day they are due", legacy: ""),
        Setting(section: "", key: "org-agenda-log-mode-items", defaultsKey: "agendaLogModeItems", kind: .string, fallback: .string("closed clock"),
                comment: "what log mode shows, separated by spaces: closed, clock, state", legacy: ""),
        Setting(section: "", key: "org-agenda-todo-ignore-with-date", defaultsKey: "agendaTodoIgnoreWithDate", kind: .bool, fallback: .bool(false),
                comment: "the TODO list leaves out entries with any active timestamp", legacy: ""),
        Setting(section: "", key: "org-agenda-todo-ignore-scheduled", defaultsKey: "agendaTodoIgnoreScheduled", kind: .string, fallback: .string("nil"),
                comment: "the TODO list leaves out scheduled entries: nil, all, future, past, or days ahead (negative: days ago)", legacy: ""),
        Setting(section: "", key: "org-agenda-todo-ignore-deadlines", defaultsKey: "agendaTodoIgnoreDeadlines", kind: .string, fallback: .string("nil"),
                comment: "the TODO list leaves out entries with deadlines: nil, near, far, all, future, past, or days", legacy: ""),
        Setting(section: "", key: "org-agenda-todo-ignore-timestamp", defaultsKey: "agendaTodoIgnoreTimestamp", kind: .string, fallback: .string("nil"),
                comment: "the TODO list leaves out entries with other active timestamps: nil, all, future, past, or days", legacy: ""),
        Setting(section: "", key: "org-agenda-tags-todo-honor-ignore-options", defaultsKey: "agendaTagsTodoHonorIgnore", kind: .bool, fallback: .bool(false),
                comment: "the org-agenda-todo-ignore settings apply to TODO-only matches too", legacy: ""),
        Setting(section: "", key: "org-agenda-search-view-always-boolean", defaultsKey: "agendaSearchAlwaysBoolean", kind: .bool, fallback: .bool(false),
                comment: "search strings are always +word -word {regexp} snippets, never a phrase", legacy: ""),
        Setting(section: "", key: "org-agenda-search-view-force-full-words", defaultsKey: "agendaSearchForceFullWords", kind: .bool, fallback: .bool(false),
                comment: "search snippets match whole words only", legacy: ""),
        Setting(section: "", key: "org-agenda-dim-blocked-tasks", defaultsKey: "agendaDimBlockedTasks",
                kind: .choice([("t", "t"), ("nil", "nil"), ("invisible", "invisible")]), fallback: .string("t"),
                comment: "t dims entries the enforce settings block, invisible hides them (unless only checkboxes block them), nil shows them as usual", legacy: ""),
        Setting(section: "", key: "appt-message-warning-time", defaultsKey: "reminderLead", kind: .integer, fallback: .integer(12),
                comment: "minutes of warning before timed entries; APPT_WARNTIME overrides", legacy: "agenda.reminder-lead"),
        Setting(section: "", key: "org-clock-idle-time", defaultsKey: "clockIdleTime", kind: .integer, fallback: .integer(0),
                comment: "minutes idle with a clock running before asking what to do with the time; 0 never (nil)", legacy: ""),
        Setting(section: "", key: "org-clock-into-drawer", defaultsKey: "clockIntoDrawer", kind: .string, fallback: .string("t"),
                comment: "t: clock lines go in the log drawer (LOGBOOK); nil: none; a number: once there are that many; or a drawer name", legacy: ""),
        Setting(section: "", key: "org-clock-rounding-minutes", defaultsKey: "clockRoundingMinutes", kind: .integer, fallback: .integer(0),
                comment: "clocks start and end on multiples of this many minutes; 0 doesn't round", legacy: ""),
        Setting(section: "", key: "org-clock-out-remove-zero-time-clocks", defaultsKey: "clockRemoveZeroTime", kind: .bool, fallback: .bool(false),
                comment: "clocking out removes a clock line of 0:00", legacy: ""),
        Setting(section: "", key: "org-clock-in-switch-to-state", defaultsKey: "clockInSwitchToState", kind: .string, fallback: .string(""),
                comment: "the TODO keyword an entry takes when you clock in; \"\" leaves it", legacy: ""),
        Setting(section: "", key: "org-clock-out-when-done", defaultsKey: "clockOutWhenDone", kind: .string, fallback: .string("t"),
                comment: "t: marking the clocked entry done clocks out; nil: it doesn't; or keywords that clock out, separated by spaces", legacy: ""),
        Setting(section: "", key: "org-clock-history-length", defaultsKey: "clockHistoryLength", kind: .integer, fallback: .integer(5),
                comment: "recently clocked entries to remember", legacy: ""),
        Setting(section: "org-agenda-prefix-format", key: "agenda", defaultsKey: "agendaPrefixAgenda", kind: .string, fallback: .string(PrefixFormat.defaults["agenda"]!),
                comment: "%c category, %t time, %s scheduled/deadline, %e effort, %l level, %b outline path; %-12 pads", legacy: ""),
        Setting(section: "org-agenda-prefix-format", key: "todo", defaultsKey: "agendaPrefixTodo", kind: .string, fallback: .string(PrefixFormat.defaults["todo"]!),
                comment: "the TODO list", legacy: ""),
        Setting(section: "org-agenda-prefix-format", key: "tags", defaultsKey: "agendaPrefixTags", kind: .string, fallback: .string(PrefixFormat.defaults["tags"]!),
                comment: "tag and property matches", legacy: ""),
        Setting(section: "theme", key: "font", defaultsKey: "themeFont", kind: .string, fallback: .string(""),
                comment: "a monospaced font family; \"\" for the system's", legacy: ""),
        Setting(section: "theme", key: "font-size", defaultsKey: "themeFontSize", kind: .integer, fallback: .integer(13),
                comment: "points", legacy: ""),
        Setting(section: "theme", key: "line-spacing", defaultsKey: "themeLineSpacing", kind: .integer, fallback: .integer(2),
                comment: "points between lines", legacy: ""),
        Setting(section: "theme", key: "heading-size-step", defaultsKey: "themeHeadingStep", kind: .integer, fallback: .integer(1),
                comment: "points a heading is larger than the level below; level 4 and deeper are body size", legacy: ""),
        Setting(section: "theme", key: "theme-file", defaultsKey: "themeFile", kind: .string, fallback: .string(""),
                comment: "a theme in its own file in this folder, under the colors set here; colors: see default-theme.toml", legacy: ""),
        Setting(section: "orgstar", key: "save", defaultsKey: "saveMode", kind: .choice([("automatic", "automatic"), ("explicit", "explicit")]),
                fallback: .string("automatic"), comment: "automatic (1 s after typing stops) or explicit (only with ⌘S)", legacy: "general.save"),
        Setting(section: "orgstar", key: "keymap", defaultsKey: "keymap", kind: .choice([("emacs", "emacs"), ("mac", "mac"), ("doom", "doom")]),
                fallback: .string("emacs"), comment: "emacs, mac or doom; your own bindings go in keymap.toml", legacy: "general.keymap"),
        Setting(section: "orgstar", key: "option-as-meta", defaultsKey: "optionAsMeta",
                kind: .integerChoice([("left", 1), ("right", 2), ("both", 3), ("none", 0)]), fallback: .string("left"),
                comment: "left, right, both or none", legacy: "general.option-as-meta"),
        Setting(section: "orgstar", key: "tab-bar", defaultsKey: "showTabBar", kind: .bool, fallback: .bool(false),
                comment: "a tab for each open buffer above the editor (View ▸ Show Tab Bar)", legacy: ""),
        Setting(section: "orgstar", key: "show-markup", defaultsKey: "showMarkup", kind: .bool, fallback: .bool(false),
                comment: "show link brackets and emphasis markers (View ▸ Show Markup)", legacy: "editor.show-markup"),
        Setting(section: "orgstar", key: "show-hidden-files", defaultsKey: "showHiddenFiles", kind: .bool, fallback: .bool(true),
                comment: "list dotfiles and dot folders in your folders", legacy: ""),
        Setting(section: "orgstar", key: "ignored-folders", defaultsKey: "ignoredFolders", kind: .string,
                fallback: .string(ScanRules.defaultIgnoredFolders.sorted().joined(separator: " ")),
                comment: "folder names never listed or searched, separated by spaces", legacy: ""),
        Setting(section: "orgstar", key: "agenda-include-subfolders", defaultsKey: "agendaSubfolders", kind: .bool, fallback: .bool(false),
                comment: "the agenda reads org files in subfolders too", legacy: "agenda.include-subfolders"),
        Setting(section: "orgstar", key: "reminders", defaultsKey: "reminders", kind: .bool, fallback: .bool(true),
                comment: "notify before timed entries", legacy: "agenda.reminders"),
        Setting(section: "orgstar", key: "calendar-events", defaultsKey: "calendarEvents", kind: .bool, fallback: .bool(false),
                comment: "show events from Calendar in the agenda, read-only", legacy: ""),
        Setting(section: "orgstar", key: "calendar-event-calendars", defaultsKey: "calendarEventCalendars", kind: .string, fallback: .string(""),
                comment: "the calendars whose events show, by title or identifier, separated by commas; \"\" for all", legacy: ""),
        Setting(section: "orgstar", key: "global-capture-hotkey", defaultsKey: "globalCapture", kind: .bool, fallback: .bool(true),
                comment: "⌃⌥Space opens Capture from any app; templates go in capture.toml", legacy: "capture.global-hotkey"),
    ]

    /// `"-3d"` as -3; nil for anything else.
    static func dayOffset(_ s: String) -> Int? {
        guard s.hasSuffix("d"), let n = Int(s.dropLast().replacingOccurrences(of: "+", with: "")) else { return nil }
        return n
    }

    // MARK: - Values

    /// The file value for what `defaults` holds, or the fallback.
    public static func value(_ setting: Setting, in defaults: UserDefaults) -> TOML.Value {
        guard defaults.object(forKey: setting.defaultsKey) != nil else { return setting.fallback }
        switch setting.kind {
        case .bool: return .bool(defaults.bool(forKey: setting.defaultsKey))
        case .integer: return .integer(defaults.integer(forKey: setting.defaultsKey))
        case .string: return .string(defaults.string(forKey: setting.defaultsKey) ?? "")
        case .choice(let choices):
            let stored = defaults.string(forKey: setting.defaultsKey)
            return choices.first { $0.stored == stored }.map { .string($0.name) } ?? setting.fallback
        case .integerChoice(let choices):
            let stored = defaults.integer(forKey: setting.defaultsKey)
            return choices.first { $0.stored == stored }.map { .string($0.name) } ?? setting.fallback
        case .dayOffset:
            let days = defaults.integer(forKey: setting.defaultsKey)
            return .string((days < 0 ? "" : "+") + "\(days)d")
        }
    }

    /// Stores a file value; a value of the wrong kind is a problem.
    static func store(_ value: TOML.Value, _ setting: Setting, in defaults: UserDefaults) -> String? {
        let key = setting.defaultsKey
        switch (setting.kind, value) {
        case (.bool, .bool(let b)): defaults.set(b, forKey: key)
        case (.integer, .integer(let i)): defaults.set(i, forKey: key)
        case (.string, .string(let s)): defaults.set(s, forKey: key)
        case (.choice(let choices), .string(let s)):
            guard let choice = choices.first(where: { $0.name == s }) else {
                return "\(setting.key) must be one of \(choices.map(\.name).joined(separator: ", "))"
            }
            defaults.set(choice.stored, forKey: key)
        case (.integerChoice(let choices), .string(let s)):
            guard let choice = choices.first(where: { $0.name == s }) else {
                return "\(setting.key) must be one of \(choices.map(\.name).joined(separator: ", "))"
            }
            defaults.set(choice.stored, forKey: key)
        case (.dayOffset, .string(let s)):
            guard let days = dayOffset(s) else { return "\(setting.key) must look like \"-3d\" or \"+0d\"" }
            defaults.set(days, forKey: key)
        default:
            return "\(setting.path) has the wrong kind of value"
        }
        return nil
    }

    /// Applies a file to `defaults`; settings it leaves out go back to their defaults.
    /// Returns problems.
    @discardableResult
    public static func apply(_ text: String, to defaults: UserDefaults) -> [String] {
        let tables: [TOML.Table]
        do { tables = try TOML.parse(text) } catch { return ["config.toml: \(error)"] }
        var problems: [String] = []
        let present = Set(tables.flatMap { table in table.values.keys.map { path(table.name, $0) } })
        for setting in settings where !present.contains(setting.path) && !present.contains(setting.legacy) {
            if defaults.object(forKey: setting.defaultsKey) != nil { defaults.removeObject(forKey: setting.defaultsKey) }
        }
        let templates = tables.first { $0.name == structureTemplateTable }
        if templates == nil, defaults.object(forKey: structureTemplatesKey) != nil { defaults.removeObject(forKey: structureTemplatesKey) }
        for table in tables {
            if table.name == structureTemplateTable {
                var rows: [String] = []
                for key in table.keys {
                    guard let type = table.values[key]?.string, !type.isEmpty else {
                        problems.append("config.toml: \(structureTemplateTable).\(key) must be a block type, such as \"src python\"")
                        continue
                    }
                    rows.append(key + "\t" + type)
                }
                if defaults.stringArray(forKey: structureTemplatesKey) != rows { defaults.set(rows, forKey: structureTemplatesKey) }
                continue
            }
            // Colors are the theme's to read.
            if ThemeSpec.isThemeTable(table.name), table.name != "theme" { continue }
            for (key, value) in table.values.sorted(by: { $0.key < $1.key }) {
                if table.name == "theme", !ThemeSpec.typeKeys.contains(key) { continue }
                let name = path(table.name, key)
                guard let setting = settings.first(where: { $0.path == name || $0.legacy == name }) else {
                    problems.append("config.toml: unknown setting \(name)")
                    continue
                }
                if let current = currentValue(setting, in: defaults), current == value { continue }
                if let problem = store(value, setting, in: defaults) { problems.append("config.toml: \(problem)") }
            }
        }
        return problems
    }

    /// `[org-structure-template-alist]`: block templates by key, over Org's, as
    /// `key = "type"`. Kept in user defaults under `structureTemplatesKey` as `key<Tab>type`.
    public static let structureTemplateTable = "org-structure-template-alist"
    static let structureTemplatesKey = "structureTemplates"

    /// The templates of `[org-structure-template-alist]`.
    public static func structureTemplates(_ defaults: UserDefaults) -> [StructureTemplate] {
        (defaults.stringArray(forKey: structureTemplatesKey) ?? []).compactMap { row in
            guard let tab = row.firstIndex(of: "\t") else { return nil }
            return StructureTemplate(key: String(row[..<tab]), type: String(row[row.index(after: tab)...]))
        }
    }

    public static func setStructureTemplates(_ templates: [StructureTemplate], in defaults: UserDefaults) {
        defaults.set(templates.map { $0.key + "\t" + $0.type }, forKey: structureTemplatesKey)
    }

    static func path(_ section: String, _ key: String) -> String { section.isEmpty ? key : section + "." + key }

    /// Whether the file uses names from before settings took Emacs's names.
    public static func usesLegacyNames(_ text: String) -> Bool {
        let names = Set(settings.map(\.legacy))
        return values(in: text).keys.contains { names.contains($0) }
    }

    /// `text` with settings under their old names moved to their current names and places,
    /// keeping comments and everything else. A section the move leaves empty is removed.
    public static func migratingLegacyNames(_ text: String) -> String {
        let values = values(in: text)
        var blocks: [[String]] = [[]]
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { blocks.append([]) }
            blocks[blocks.count - 1].append(line)
        }
        var moves: [(setting: Setting, value: TOML.Value, comment: String)] = []
        var kept: [String] = []
        for block in blocks {
            let header = block.first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.hasPrefix("[") ? $0 : nil }
            let section = header.map { String($0.dropFirst().prefix { $0 != "]" }).trimmingCharacters(in: .whitespaces) } ?? ""
            var remaining: [String] = []
            for (index, line) in block.enumerated() {
                guard header == nil || index > 0, let equals = line.firstIndex(of: "=") else {
                    remaining.append(line)
                    continue
                }
                let name = path(section, line[..<equals].trimmingCharacters(in: .whitespaces))
                guard let setting = settings.first(where: { !$0.legacy.isEmpty && $0.legacy == name }), let value = values[name] else {
                    remaining.append(line)
                    continue
                }
                // A setting also under its new name keeps that one.
                if values[setting.path] == nil {
                    moves.append((setting, value, commentStart(line, after: equals).map { String(line[$0...]) } ?? ""))
                }
            }
            let emptied = header != nil && remaining.count < block.count
                && remaining.dropFirst().allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !emptied { kept += remaining }
        }
        var out = kept.joined(separator: "\n")
        if text.hasSuffix("\n"), !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        for move in moves {
            out = setting(out, section: move.setting.section, key: move.setting.key, to: move.value)
            guard !move.comment.isEmpty else { continue }
            var lines = out.components(separatedBy: "\n")
            if let index = lines.firstIndex(of: "\(move.setting.key) = \(format(move.value))") {
                lines[index] += "  " + move.comment
                out = lines.joined(separator: "\n")
            }
        }
        return out
    }

    private static func currentValue(_ setting: Setting, in defaults: UserDefaults) -> TOML.Value? {
        defaults.object(forKey: setting.defaultsKey) == nil ? nil : value(setting, in: defaults)
    }

    /// The values a file sets, by `section.key`.
    static func values(in text: String) -> [String: TOML.Value] {
        guard let tables = try? TOML.parse(text) else { return [:] }
        var result: [String: TOML.Value] = [:]
        for table in tables { for (key, value) in table.values { result[path(table.name, key)] = value } }
        return result
    }

    // MARK: - Text

    static func format(_ value: TOML.Value) -> String {
        switch value {
        case .bool(let b): b ? "true" : "false"
        case .integer(let i): String(i)
        case .string(let s):
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
        }
    }

    /// A commented file with every setting at its current value.
    public static func template(from defaults: UserDefaults) -> String {
        template { value($0, in: defaults) }
    }

    /// A commented file with every setting at its default.
    public static var defaultTemplate: String { template(\.fallback) }

    private static func template(_ value: (Setting) -> TOML.Value) -> String {
        var out = """
            # orgstar settings. The Settings window writes its changes here, and edits made here
            # apply while orgstar runs. Keys go in keymap.toml, capture templates in capture.toml
            # and saved agenda views in views.toml, all in this folder.

            # Emacs variables, by their Emacs names.

            """
        var section = ""
        for setting in settings {
            if setting.section != section {
                section = setting.section
                out += "\n[\(section)]\n"
            }
            out += "\(setting.key) = \(format(value(setting)))  # \(setting.comment)\n"
        }
        return out
    }

    /// `text` with the sections it lacks entirely added at the end, every setting at its
    /// value in `defaults`: how a file from an earlier version gets settings added since.
    /// Single lines left out stay out; they mean the default.
    public static func addingMissingSections(_ text: String, from defaults: UserDefaults) -> String {
        let tables = (try? TOML.parse(text)) ?? []
        let present = Set(tables.filter { !$0.values.isEmpty || $0.name != "" }.map(\.name))
        var out = text
        var section: String?
        for setting in settings where !setting.section.isEmpty && !present.contains(setting.section) {
            if setting.section != section {
                section = setting.section
                if !out.hasSuffix("\n") { out += "\n" }
                out += "\n[\(setting.section)]\n"
            }
            out += "\(setting.key) = \(format(value(setting, in: defaults)))  # \(setting.comment)\n"
        }
        return out
    }

    /// `text` with `section.key` set to `value`: the line's value is replaced (its comment
    /// stays), or a line is added at the end of the section, or the section at the end.
    public static func setting(_ text: String, section: String, key: String, to value: TOML.Value) -> String {
        var lines = text.components(separatedBy: "\n")
        var current = ""
        var lastInSection: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                current = String(trimmed.dropFirst().prefix { $0 != "]" }).trimmingCharacters(in: .whitespaces)
                if current == section { lastInSection = index }
                continue
            }
            guard current == section else { continue }
            if !trimmed.isEmpty { lastInSection = index }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            let comment = commentStart(line, after: equals).map { "  " + line[$0...] } ?? ""
            lines[index] = line[..<equals] + "= " + format(value) + comment
            return lines.joined(separator: "\n")
        }
        if let lastInSection {
            lines.insert("\(key) = \(format(value))", at: lastInSection + 1)
        } else if section.isEmpty {
            let firstHeader = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            lines.insert(contentsOf: ["\(key) = \(format(value))", ""], at: firstHeader)
        } else {
            if lines.last == "" { lines.removeLast() }
            lines += ["", "[\(section)]", "\(key) = \(format(value))", ""]
        }
        return lines.joined(separator: "\n")
    }

    /// Where a `#` comment starts after the value, outside quotes.
    private static func commentStart(_ line: String, after equals: String.Index) -> String.Index? {
        var quote: Character?
        var index = line.index(after: equals)
        while index < line.endIndex {
            let c = line[index]
            if let q = quote {
                if c == "\\" && q == "\"" { index = line.index(after: index) } else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return index
            }
            if index < line.endIndex { index = line.index(after: index) }
        }
        return nil
    }
}
