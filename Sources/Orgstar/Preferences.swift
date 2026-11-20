import Foundation
import OrgApp
import OrgCore

/// Org preferences, stored in user defaults by the Settings window.
enum Preferences {
    static let defaultTodoKeywords = OrgPreferences.defaultTodoKeywords

    #if APPSTORE
    /// The folder chosen with Choose Configuration Folder…, used before anything reads the
    /// configuration.
    private static let chosenConfigFolder: Void = { UserConfig.directoryOverride = ConfigFolder.resolve() }()
    #endif

    /// TODO keywords for files without `#+TODO`, read at launch.
    @MainActor
    static var orgSettings: OrgSettings {
        #if APPSTORE
        _ = chosenConfigFolder
        #endif
        // config.toml applies before anything reads settings.
        ConfigSync.shared.start()
        return OrgPreferences.orgSettings()
    }

    static func options(
        tagsColumn: Int, headingAfterSubtree: Bool, splitLine: Bool, alphabeticalLists: Bool, fillColumn: Int,
        hiddenMarkers: Bool, prettyEntities: Bool, logDone: String, logIntoDrawer: String,
        hideDrawerStartup: Bool, hideBlockStartup: Bool, logReschedule: String, logRedeadline: String, useSpeedCommands: Bool, startupWithInlineImages: Bool,
        startupIndented: Bool, hideLeadingStars: Bool, startupAlignAllTables: Bool, startupTruncated: Bool, spellCheck: Bool, electricPair: Bool,
        enforceTodoDependencies: Bool, enforceTodoCheckboxDependencies: Bool
    ) -> EditingOptions {
        // The settings only config.toml has, under those the Settings window binds.
        var options = OrgPreferences.options()
        options.tagsColumn = tagsColumn
        options.insertHeadingRespectContent = headingAfterSubtree
        options.metaReturnMaySplitLine = splitLine
        options.listAllowAlphabetical = alphabeticalLists
        options.fillColumn = fillColumn
        options.hideEmphasisMarkers = hiddenMarkers
        options.prettyEntities = prettyEntities
        options.subSuperscriptsNeedBraces = true
        options.logDone = LogHow(rawValue: logDone)
        options.logIntoDrawer = logIntoDrawer.isEmpty ? nil : logIntoDrawer
        options.hideDrawerStartup = hideDrawerStartup
        options.hideBlockStartup = hideBlockStartup
        options.logReschedule = LogHow(rawValue: logReschedule)
        options.logRedeadline = LogHow(rawValue: logRedeadline)
        options.useSpeedCommands = useSpeedCommands
        options.startupWithInlineImages = startupWithInlineImages
        options.startupIndented = startupIndented
        options.hideLeadingStars = hideLeadingStars
        options.startupAlignAllTables = startupAlignAllTables
        options.startupTruncated = startupTruncated
        options.spellCheck = spellCheck
        options.electricPair = electricPair
        options.enforceTodoDependencies = enforceTodoDependencies
        options.enforceTodoCheckboxDependencies = enforceTodoCheckboxDependencies
        return options
    }
}
