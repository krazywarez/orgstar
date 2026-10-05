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
            // A file from before settings took Emacs's names is written again with them; one
            // from before a section existed gets the section.
            if let text, UserConfig.usesLegacyNames(text) {
                let template = UserConfig.template(from: defaults)
                try? template.write(to: url, atomically: true, encoding: .utf8)
                self.text = template
            } else if let text {
                let completed = UserConfig.addingMissingSections(text, from: defaults)
                if completed != text {
                    try? completed.write(to: url, atomically: true, encoding: .utf8)
                    self.text = completed
                }
            }
        } else {
            let template = UserConfig.template(from: defaults)
            try? template.write(to: url, atomically: true, encoding: .utf8)
            text = template
        }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeBack() }
        }
        guard watch else { return }
        let directory = url.deletingLastPathComponent()
        watcher = FSEventsWatcher(roots: [directory.resolvingSymlinksInPath()]) { [weak self] events in
            let names = Set(events.compactMap { event -> String? in
                if case .changed(let url) = event { return url.lastPathComponent }
                return nil
            })
            Task { @MainActor [weak self] in
                guard let self else { return }
                for name in names.sorted() {
                    if name == self.url.lastPathComponent { self.reload() }
                    if name == self.defaults.string(forKey: "themeFile") { self.readTheme() }
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

    /// The theme from the file read last and its theme file.
    func readTheme() {
        guard let text, let tables = try? TOML.parse(text) else { return }
        var spec = ThemeSpec.default
        var themeProblems: [String] = []
        if let name = defaults.string(forKey: "themeFile"), !name.isEmpty {
            let file = url.deletingLastPathComponent().appendingPathComponent(name)
            if let themeText = try? String(contentsOf: file, encoding: .utf8) {
                do {
                    (spec, themeProblems) = ThemeSpec.reading(try TOML.parse(themeText), file: name)
                } catch {
                    themeProblems.append("\(name): \(error)")
                }
            } else {
                themeProblems.append("config.toml: theme-file \(name) can't be read")
            }
        }
        let (merged, more) = ThemeSpec.reading(tables, over: spec)
        if merged != theme { theme = merged }
        problems = configProblems + themeProblems + more
    }

    /// Writes settings that differ from the file into it.
    func writeBack() {
        guard !applying, var current = text ?? (try? String(contentsOf: url, encoding: .utf8)) else { return }
        let values = UserConfig.values(in: current)
        let original = current
        for setting in UserConfig.settings where defaults.object(forKey: setting.defaultsKey) != nil {
            let value = UserConfig.value(setting, in: defaults)
            if values[setting.path] != value {
                current = UserConfig.setting(current, section: setting.section, key: setting.key, to: value)
            }
        }
        guard current != original else { return }
        text = current
        try? current.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
