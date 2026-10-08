import Foundation
import OrgCore

/// The Org settings `config.toml` holds, read from user defaults with the file's fallbacks, for
/// both apps.
public enum OrgPreferences {
    public static let defaultTodoKeywords = "TODO(t) PROJ(p) LOOP(r) STRT(s) WAIT(w) HOLD(h) IDEA(i) | DONE(d) KILL(k)"

    /// TODO keywords for files without `#+TODO`, and alphabetical lists.
    public static func orgSettings(_ defaults: UserDefaults = .standard) -> OrgSettings {
        let line = defaults.string(forKey: "todoKeywords") ?? defaultTodoKeywords
        var settings = OrgSettings.default.withTodoKeywords(line) ?? .default
        settings.listAllowAlphabetical = bool("alphabeticalLists", defaults)
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
        return options
    }

    public static func agendaSpan(_ defaults: UserDefaults = .standard) -> Int { integer("agendaSpan", defaults) }
    public static func agendaStartOffset(_ defaults: UserDefaults = .standard) -> Int { integer("agendaStartOffset", defaults) }
    public static func agendaSubfolders(_ defaults: UserDefaults = .standard) -> Bool { bool("agendaSubfolders", defaults) }
    public static func reminders(_ defaults: UserDefaults = .standard) -> Bool { bool("reminders", defaults) }
    /// `appt-message-warning-time`, in minutes.
    public static func reminderLead(_ defaults: UserDefaults = .standard) -> Int { integer("reminderLead", defaults) }

    private static func fallback(_ key: String) -> TOML.Value? {
        UserConfig.settings.first { $0.defaultsKey == key }?.fallback
    }

    private static func bool(_ key: String, _ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback(key)?.bool ?? false
    }

    private static func string(_ key: String, _ defaults: UserDefaults) -> String {
        defaults.string(forKey: key) ?? fallback(key)?.string ?? ""
    }

    /// Integers, and day offsets stored as integers with `"-3d"` as the fallback.
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
