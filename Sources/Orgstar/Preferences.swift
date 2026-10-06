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
        return OrgSettings.default.withTodoKeywords(line) ?? .default
    }

    static func options(
        tagsColumn: Int, headingAfterSubtree: Bool, splitLine: Bool, alphabeticalLists: Bool, fillColumn: Int,
        hiddenMarkers: Bool, prettyEntities: Bool, logDone: String, logIntoDrawer: String,
        hideDrawerStartup: Bool, hideBlockStartup: Bool
    ) -> EditingOptions {
        EditingOptions(
            tagsColumn: tagsColumn, insertHeadingRespectContent: headingAfterSubtree,
            metaReturnMaySplitLine: splitLine, listAllowAlphabetical: alphabeticalLists, fillColumn: fillColumn,
            hideEmphasisMarkers: hiddenMarkers, prettyEntities: prettyEntities, subSuperscriptsNeedBraces: true,
            logDone: LogHow(rawValue: logDone), logIntoDrawer: logIntoDrawer.isEmpty ? nil : logIntoDrawer,
            hideDrawerStartup: hideDrawerStartup, hideBlockStartup: hideBlockStartup
        )
    }
}
