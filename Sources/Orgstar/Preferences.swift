import Foundation
import OrgApp
import OrgCore

/// Org preferences, stored in user defaults by the Settings window.
enum Preferences {
    static let defaultTodoKeywords = "TODO(t) PROJ(p) LOOP(r) STRT(s) WAIT(w) HOLD(h) IDEA(i) | DONE(d) KILL(k)"

    /// TODO keywords for files without `#+TODO`, read at launch.
    @MainActor
    static var orgSettings: OrgSettings {
        // config.toml applies before anything reads settings.
        ConfigSync.shared.start()
        let line = UserDefaults.standard.string(forKey: "todoKeywords") ?? defaultTodoKeywords
        var settings = OrgSettings.default.withTodoKeywords(line) ?? .default
        settings.listAllowAlphabetical = UserDefaults.standard.object(forKey: "alphabeticalLists") as? Bool ?? true
        return settings
    }

    static func options(
        tagsColumn: Int, headingAfterSubtree: Bool, splitLine: Bool, alphabeticalLists: Bool, fillColumn: Int,
        hiddenMarkers: Bool, prettyEntities: Bool, logDone: String, logIntoDrawer: String,
        hideDrawerStartup: Bool, hideBlockStartup: Bool, logReschedule: String, logRedeadline: String, useSpeedCommands: Bool, startupWithInlineImages: Bool,
        startupIndented: Bool, hideLeadingStars: Bool, startupAlignAllTables: Bool, startupTruncated: Bool, spellCheck: Bool
    ) -> EditingOptions {
        EditingOptions(
            tagsColumn: tagsColumn, insertHeadingRespectContent: headingAfterSubtree,
            metaReturnMaySplitLine: splitLine, listAllowAlphabetical: alphabeticalLists, fillColumn: fillColumn,
            hideEmphasisMarkers: hiddenMarkers, prettyEntities: prettyEntities, subSuperscriptsNeedBraces: true,
            logDone: LogHow(rawValue: logDone), logIntoDrawer: logIntoDrawer.isEmpty ? nil : logIntoDrawer,
            hideDrawerStartup: hideDrawerStartup, hideBlockStartup: hideBlockStartup,
            logReschedule: LogHow(rawValue: logReschedule), logRedeadline: LogHow(rawValue: logRedeadline),
            useSpeedCommands: useSpeedCommands, startupWithInlineImages: startupWithInlineImages,
            startupIndented: startupIndented, hideLeadingStars: hideLeadingStars, startupAlignAllTables: startupAlignAllTables,
            startupTruncated: startupTruncated, spellCheck: spellCheck
        )
    }
}
