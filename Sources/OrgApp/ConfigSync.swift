#if os(macOS)
import Foundation
import OrgCore
import OrgPresentation
import OrgWorkspace

/// Keeps `config.toml` and the settings in user defaults the same: the file applies at launch
/// and whenever it changes on disk, and a change made in the app is written into the file. A
/// missing file is created with every setting at its current value.
@MainActor
@Observable
public final class ConfigSync {
    public static let shared = ConfigSync()

    /// Problems in the file, from the last time it was read.
    public private(set) var problems: [String] = []
    /// The colors of `[theme]`, `[theme.light]`, `[theme.dark]` and `[theme.todo]` over the
    /// default theme, with `theme-file`'s under them.
    public private(set) var theme = ThemeSpec.default
    /// The last file of the configuration folder that changed, with a serial number.
    public private(set) var changedFile: (name: String, serial: Int)?

    private let url: URL
    private let defaults: UserDefaults
    @ObservationIgnored private var text: String?
    @ObservationIgnored private var configProblems: [String] = []
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var watcher: FSEventsWatcher?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var serial = 0

    /// Where `url` leads: a symlinked config.toml is written through, not replaced by a file.
    private var target: URL { url.resolvingSymlinksInPath() }

    public init(url: URL = UserConfig.configFile, defaults: UserDefaults = .standard) {
        self.url = url
        self.defaults = defaults
    }

    public func start(watch: Bool = true) {
        guard observer == nil else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reference = url.deletingLastPathComponent().appendingPathComponent("default-theme.toml")
        if (try? String(contentsOf: reference, encoding: .utf8)) != ThemeSpec.defaultThemeFile() {
            try? ThemeSpec.defaultThemeFile().write(to: reference, atomically: true, encoding: .utf8)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            reload()
            // A file from before settings took Emacs's names gets them in place; one from
            // before a section existed gets the section.
            if let text {
                let migrated = UserConfig.usesLegacyNames(text) ? UserConfig.migratingLegacyNames(text) : text
                let completed = UserConfig.addingMissingSections(migrated, from: defaults)
                if completed != text {
                    try? completed.write(to: target, atomically: true, encoding: .utf8)
                    self.text = completed
                }
            }
        } else {
            let template = UserConfig.template(from: defaults)
            try? template.write(to: target, atomically: true, encoding: .utf8)
            text = template
        }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeBack() }
        }
        guard watch else { return }
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        // The linked file's folder too, when config.toml is a symlink.
        let linked = target.deletingLastPathComponent().resolvingSymlinksInPath()
        let watchesLinked = linked.path != directory.path
        // Files still read from where earlier versions kept them reload when edited there too.
        let legacy = UserConfig.legacyDirectory.resolvingSymlinksInPath()
        let watchesLegacy = legacy.path != directory.path && FileManager.default.fileExists(atPath: legacy.path)
        watcher = FSEventsWatcher(roots: [directory] + (watchesLinked ? [linked] : []) + (watchesLegacy ? [legacy] : [])) { [weak self] events in
            let changed = Set(events.compactMap { event -> URL? in
                if case .changed(let url) = event { return url }
                return nil
            })
            Task { @MainActor [weak self] in
                guard let self else { return }
                for file in changed.sorted(by: { $0.path < $1.path }) {
                    if !file.path.hasPrefix(directory.path + "/"),
                       UserConfig.file(file.lastPathComponent).resolvingSymlinksInPath().path != file.resolvingSymlinksInPath().path { continue }
                    let name = file.lastPathComponent
                    if name == self.url.lastPathComponent { self.reload() }
                    if self.isThemeFile(file) { self.readTheme() }
                    self.serial += 1
                    self.changedFile = (name, self.serial)
                }
            }
        }
        watcher?.start()
    }

    /// Reads the file and applies it when it changed since the last read or write.
    public func reload() {
        guard let new = try? String(contentsOf: url, encoding: .utf8), new != text else { return }
        text = new
        applying = true
        configProblems = UserConfig.apply(new, to: defaults)
        applying = false
        readTheme()
    }

    /// `theme-file`, relative to the configuration folder.
    private var themeFile: URL? {
        guard let name = defaults.string(forKey: "themeFile"), !name.isEmpty else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Whether `file`, as the watcher reports it, is `theme-file`, which may be in a subfolder.
    func isThemeFile(_ file: URL) -> Bool {
        themeFile?.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path
    }

    /// The theme from the file read last and its theme file.
    func readTheme() {
        guard let text, let read = UserConfig.theme(
            config: text, themeFile: defaults.string(forKey: "themeFile"),
            lightTheme: defaults.string(forKey: "themeLight"), darkTheme: defaults.string(forKey: "themeDark"),
            in: url.deletingLastPathComponent()
        ) else { return }
        if read.theme != theme { theme = read.theme }
        problems = configProblems + read.problems
    }

    /// Writes settings that differ from the file into it.
    func writeBack() {
        // The file as it is now, so that tables written into it since, as by Emacs import, stay.
        guard !applying, var current = (try? String(contentsOf: url, encoding: .utf8)) ?? text else { return }
        let values = UserConfig.values(in: current)
        let original = current
        for setting in UserConfig.settings where defaults.object(forKey: setting.defaultsKey) != nil {
            let value = UserConfig.value(setting, in: defaults)
            if values[setting.path] != value {
                current = UserConfig.setting(current, section: setting.section, key: setting.key, to: value)
            }
        }
        // Templates added in the app, as by Emacs import; removing one is done in the file.
        for template in UserConfig.structureTemplates(defaults) where values[UserConfig.path(UserConfig.structureTemplateTable, template.key)] != .string(template.type) {
            current = UserConfig.setting(current, section: UserConfig.structureTemplateTable, key: template.key, to: .string(template.type))
        }
        guard current != original else { return }
        text = current
        try? current.write(to: target, atomically: true, encoding: .utf8)
        // A theme picked in Settings; the watcher's reload sees the text unchanged and skips it.
        readTheme()
    }
}
#endif
