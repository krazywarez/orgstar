#if os(iOS)
import Foundation
import Observation
import OrgApp
import OrgCore
import OrgIndex
import OrgWorkspace

/// The app's models, and the settings from the configuration folder: a folder you choose
/// (a synced copy of the Mac's `~/.config/orgstar`) with `config.toml` and `capture.toml`.
@MainActor
@Observable
final class MobileModel {
    let workspace: WorkspaceModel?
    let failure: String?
    let session = DocumentSession()
    let agenda: AgendaModel?
    let scheduler = ReminderScheduler(center: SystemReminderCenter())
    let clock = ClockModel()
    let spotlight = SpotlightIndexer()
    private(set) var configFolder: URL?
    private(set) var configProblems: [String] = []
    /// An entry to show, from a tapped reminder.
    var openRequest: ReaderRoute?
    /// Bumped when settings apply, so views that read them update.
    private(set) var settingsVersion = 0
    @ObservationIgnored private var presenter: FolderPresenter?

    private static let bookmarkKey = "configFolderBookmark"

    init() {
        // Development: `ORGSTAR_CONFIG_DIR` stands in for a chosen folder.
        let folder = Self.resolveBookmark() ?? ProcessInfo.processInfo.environment["ORGSTAR_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        UserConfig.directoryOverride = folder
        let problems = Self.readConfig(folder)
        let settings = OrgPreferences.orgSettings()
        do {
            let workspace = try WorkspaceModel(directory: WorkspaceModel.defaultDirectory, settings: .with(todoKeywords: settings))
            self.workspace = workspace
            agenda = AgendaModel(workspace: workspace)
            failure = nil
        } catch {
            workspace = nil
            agenda = nil
            failure = error.localizedDescription
        }
        configFolder = folder
        configProblems = problems
        applySettings()
        watchConfig()
    }

    /// Chooses the configuration folder, or with nil stops using one; its settings apply now.
    func setConfigFolder(_ url: URL?) {
        if let url {
            _ = url.startAccessingSecurityScopedResource()
            if let bookmark = try? url.bookmarkData() { UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey) }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            // What the folder set no longer applies.
            for setting in UserConfig.settings { UserDefaults.standard.removeObject(forKey: setting.defaultsKey) }
        }
        configFolder = url
        reloadConfig()
        watchConfig()
    }

    func reloadConfig() {
        UserConfig.directoryOverride = configFolder
        configProblems = Self.readConfig(configFolder)
        applySettings()
    }

    private func applySettings() {
        let settings = OrgPreferences.orgSettings()
        session.defaults = settings
        session.options = OrgPreferences.options()
        workspace?.settings = .with(todoKeywords: settings)
        if let agenda {
            agenda.span = OrgPreferences.agendaSpan()
            agenda.startOffset = OrgPreferences.agendaStartOffset()
            agenda.includeSubfolders = OrgPreferences.agendaSubfolders()
        }
        settingsVersion += 1
    }

    /// Edits to the folder's files, synced from the Mac, apply as they arrive.
    private func watchConfig() {
        presenter?.stop()
        presenter = nil
        guard let configFolder else { return }
        let presenter = FolderPresenter(root: configFolder) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadConfig() }
        }
        presenter.start()
        self.presenter = presenter
    }

    private static func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: bookmarkKey) }
        return url
    }

    /// Applies the folder's `config.toml` to the settings; returns its problems.
    private static func readConfig(_ folder: URL?) -> [String] {
        guard let folder else { return [] }
        let file = folder.appendingPathComponent("config.toml")
        var text: String?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &error) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        guard let text else { return ["No config.toml in \(folder.lastPathComponent); the defaults apply."] }
        return UserConfig.apply(text, to: .standard)
    }

    /// Notifications for the next week's timed entries, at most 64, as iOS allows.
    func updateReminders() async {
        guard let workspace else { return }
        guard OrgPreferences.reminders() else {
            await scheduler.clear()
            return
        }
        guard !workspace.files.isEmpty else { return }
        let agenda = AgendaModel(workspace: workspace)
        agenda.includeSubfolders = OrgPreferences.agendaSubfolders()
        let reminders = await agenda.reminders(open: session.openTexts, lead: OrgPreferences.reminderLead())
        await scheduler.reconcile(reminders)
    }
}
#endif
