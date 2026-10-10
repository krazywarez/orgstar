#if os(iOS)
import Foundation
import Observation
import OrgApp
import OrgCore
import OrgIndex
import OrgPresentation
import OrgWorkspace
import UIKit
import UserNotifications
import WidgetKit

/// The app's models, and the settings from the configuration folder: a folder you choose
/// (a synced copy of the Mac's `~/.config/orgstar`) with `config.toml` and `capture.toml`.
@MainActor
@Observable
final class MobileModel {
    /// One per process: Shortcuts runs the capture action without a window.
    static let shared = MobileModel()

    let workspace: WorkspaceModel?
    let failure: String?
    let session = DocumentSession()
    let agenda: AgendaModel?
    let scheduler = ReminderScheduler(center: SystemReminderCenter())
    let clock = ClockModel()
    let clockPrompts = ClockPrompter()
    let spotlight = SpotlightIndexer()
    /// Captures from the share extension; nil without the app group.
    let inbox = CaptureInbox()
    private(set) var configFolder: URL?
    private(set) var configProblems: [String] = []
    /// An entry to show, from a tapped reminder.
    var openRequest: ReaderRoute?
    /// Agenda days to show, from a followed timestamp: the first (a `Days` number) and how many.
    var agendaRequest: AgendaDays?
    /// A capture to show, from the agenda.
    var captureRequest: CaptureRequest?
    /// Calendar's events for the agenda, with `calendar-events`.
    let calendarEvents = CalendarEvents()

    struct AgendaDays: Equatable {
        let start: Int
        let count: Int
    }
    /// Bumped when settings apply, so views that read them update.
    private(set) var settingsVersion = 0
    /// The theme from `config.toml` and its theme file, with the type settings.
    private(set) var theme = ThemeSpec.default
    /// `show-markup`, toggled in the editor; the folder's value applies when it changes.
    var showMarkup = false
    /// `org-stored-links`, most recent first; kept while the app runs, as in Emacs.
    var storedLinks: [StoredLink] = []
    @ObservationIgnored private var configShowMarkup: Bool?
    @ObservationIgnored private var presenter: FolderPresenter?
    @ObservationIgnored private var sizeObserver: NSObjectProtocol?

    private static let bookmarkKey = "configFolderBookmark"

    private init() {
        // Development: `ORGSTAR_CONFIG_DIR` stands in for a chosen folder.
        let folder = Self.resolveBookmark() ?? ProcessInfo.processInfo.environment["ORGSTAR_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        UserConfig.directoryOverride = folder
        let (problems, colors) = Self.readConfig(folder)
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
        applySettings(colors)
        shareTemplates()
        watchConfig()
        // A new Dynamic Type size restyles editors and the reader.
        sizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsVersion += 1 }
        }
    }

    /// Chooses the configuration folder, or with nil stops using one; its settings apply now.
    func setConfigFolder(_ url: URL?) {
        if let url {
            _ = url.startAccessingSecurityScopedResource()
            if let bookmark = try? url.bookmarkData() { UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey) }
            Self.createConfig(in: url)
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
        let interval = Perf.begin("config.reload")
        defer { interval.end() }
        UserConfig.directoryOverride = configFolder
        let (problems, colors) = Self.readConfig(configFolder)
        configProblems = problems
        applySettings(colors)
        shareTemplates()
    }

    private func applySettings(_ colors: ThemeSpec) {
        theme = OrgPreferences.theme(colors)
        let markup = OrgPreferences.showMarkup()
        if markup != configShowMarkup {
            configShowMarkup = markup
            showMarkup = markup
        }
        let settings = OrgPreferences.orgSettings()
        session.defaults = settings
        session.options = OrgPreferences.options()
        workspace?.settings = .with(todoKeywords: settings)
        if let agenda {
            agenda.span = OrgPreferences.agendaSpan()
            agenda.startOffset = OrgPreferences.agendaStartOffset()
            agenda.includeSubfolders = OrgPreferences.agendaSubfolders()
            agenda.options = OrgPreferences.agendaOptions(agenda.options)
            agenda.calendarEvents = OrgPreferences.calendarEvents() ? calendarEvents : nil
            agenda.calendarNames = OrgPreferences.calendarEventCalendars()
        }
        settingsVersion += 1
    }

    /// The folder's `config.toml`, read in coordination with the app that syncs it.
    func configText() -> String? {
        configFolder.flatMap { Self.read($0.appendingPathComponent("config.toml")) }
    }

    /// Writes the folder's `config.toml` and applies it.
    func saveConfig(_ text: String) {
        guard let configFolder else { return }
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: configFolder.appendingPathComponent("config.toml"), options: [], error: &error) { url in
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        reloadConfig()
    }

    /// Changes a setting from the app: in the folder's config.toml when there is a folder, as
    /// the Mac's Settings write it, else in this device's settings.
    func set(_ defaultsKey: String, to value: TOML.Value) {
        guard let setting = UserConfig.settings.first(where: { $0.defaultsKey == defaultsKey }) else { return }
        if let configFolder {
            let file = configFolder.appendingPathComponent("config.toml")
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: [], error: &error) { url in
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? UserConfig.setting(text, section: setting.section, key: setting.key, to: value).write(to: url, atomically: true, encoding: .utf8)
            }
        } else {
            switch value {
            case .bool(let b): UserDefaults.standard.set(b, forKey: defaultsKey)
            case .string(let s): UserDefaults.standard.set(s, forKey: defaultsKey)
            case .integer(let i): UserDefaults.standard.set(i, forKey: defaultsKey)
            }
        }
        reloadConfig()
    }

    /// The capture templates, for the share extension to offer.
    private func shareTemplates() {
        try? inbox?.setTemplates(CaptureTemplates.load().templates.map { CaptureInbox.Template(key: $0.key, name: $0.name) })
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

    /// Applies the folder's `config.toml` to the settings; returns its problems and the theme's
    /// colors.
    /// Writes `config.toml` with every setting at its default when the folder has none.
    private static func createConfig(in folder: URL) {
        let file = folder.appendingPathComponent("config.toml")
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: [], error: &error) { url in
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try? UserConfig.defaultTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func readConfig(_ folder: URL?) -> ([String], ThemeSpec) {
        guard let folder else { return ([], .default) }
        guard let text = read(folder.appendingPathComponent("config.toml")) else {
            return (["No config.toml in \(folder.lastPathComponent); the defaults apply."], .default)
        }
        let problems = UserConfig.apply(text, to: .standard)
        guard let theme = UserConfig.theme(config: text, themeFile: UserDefaults.standard.string(forKey: "themeFile"), in: folder, read: read) else {
            return (problems, .default)
        }
        return (problems + theme.problems, theme.theme)
    }

    /// A file of the folder, read in coordination with the app that syncs it.
    private static func read(_ file: URL) -> String? {
        var text: String?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file, options: [], error: &error) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return text
    }

    /// Notifications for the next week's timed entries, at most 64, as iOS allows.
    func updateReminders() async {
        let interval = Perf.begin("reminders.update")
        defer { interval.end() }
        guard let workspace else { return }
        guard OrgPreferences.reminders() else {
            await scheduler.clear()
            return
        }
        guard !workspace.files.isEmpty else { return }
        // The agenda's cache and options, so files it has read aren't read again.
        let agenda = AgendaModel(workspace: workspace, cache: self.agenda?.cache ?? AgendaSourceCache())
        agenda.includeSubfolders = OrgPreferences.agendaSubfolders()
        if let options = self.agenda?.options { agenda.options = options }
        let reminders = await agenda.reminders(open: session.openTexts, lead: OrgPreferences.reminderLead())
        await scheduler.reconcile(reminders)
    }

    /// The widgets' agenda: today and the next days in the app group's container, with the
    /// widgets reloaded when it changed; and the icon's overdue badge.
    func updateWidgets() async {
        let interval = Perf.begin("widgets.update")
        defer { interval.end() }
        guard let workspace else { return }
        let days = AgendaModel(workspace: workspace, cache: agenda?.cache ?? AgendaSourceCache())
        days.mode = .agenda(span: AgendaSnapshot.dayCount, startOffset: 0)
        if let agenda {
            days.includeSubfolders = agenda.includeSubfolders
            days.options = agenda.options
            days.options.logMode = false
            days.calendarEvents = agenda.calendarEvents
            days.calendarNames = agenda.calendarNames
        }
        await days.refresh(open: session.openTexts)
        await updateBadge(OverdueBadge.counts(days.groups(), today: days.today, days: AgendaSnapshot.dayCount))
        guard let file = AgendaSnapshot.file() else { return }
        let snapshot = AgendaSnapshot(groups: days.groups(), today: days.today, theme: theme, generated: Date())
        if (try? snapshot.write(to: file)) == true { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Today's count on the icon, and each later day's set for its midnight by a notification
    /// that only changes the badge.
    private func updateBadge(_ counts: [Int]) async {
        let center = UNUserNotificationCenter.current()
        guard await badgesEnabled(asking: true) else { return }
        try? await center.setBadgeCount(counts.first ?? 0)
        center.removePendingNotificationRequests(withIdentifiers: (1..<AgendaSnapshot.dayCount).map(Self.badgeID))
        let today = Calendar.current.startOfDay(for: Date())
        for (offset, count) in counts.enumerated().dropFirst() {
            guard let midnight = Calendar.current.date(byAdding: .day, value: offset, to: today) else { continue }
            let content = UNMutableNotificationContent()
            content.badge = NSNumber(value: count)
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: midnight)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.badgeID(offset), content: content, trigger: trigger))
        }
    }

    static func badgeID(_ offset: Int) -> String { "badge.\(offset)" }

    /// Whether iOS shows the icon's badge. Asking adds badges to the app's notification
    /// settings, which an earlier grant without them leaves out; iOS prompts only the first time.
    func badgesEnabled(asking: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.badgeSetting == .enabled { return true }
        guard asking, settings.authorizationStatus != .denied else { return false }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        return await center.notificationSettings().badgeSetting == .enabled
    }
}
#endif
