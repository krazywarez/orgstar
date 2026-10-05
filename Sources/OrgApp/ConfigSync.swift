#if os(macOS)
import Foundation
import OrgCore
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
    /// The last file of the configuration folder that changed, with a serial number.
    public private(set) var changedFile: (name: String, serial: Int)?

    private let url: URL
    private let defaults: UserDefaults
    @ObservationIgnored private var text: String?
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
        if FileManager.default.fileExists(atPath: url.path) {
            reload()
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
        problems = UserConfig.apply(new, to: defaults)
        applying = false
    }

    /// Writes settings that differ from the file into it.
    func writeBack() {
        guard !applying, var current = text ?? (try? String(contentsOf: url, encoding: .utf8)) else { return }
        let values = UserConfig.values(in: current)
        let original = current
        for setting in UserConfig.settings where defaults.object(forKey: setting.defaultsKey) != nil {
            let value = UserConfig.value(setting, in: defaults)
            if values[setting.section + "." + setting.key] != value {
                current = UserConfig.setting(current, section: setting.section, key: setting.key, to: value)
            }
        }
        guard current != original else { return }
        text = current
        try? current.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
