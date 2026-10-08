import Foundation
import OrgCore
import OrgPresentation
import Testing
@testable import OrgApp

@MainActor
struct UserConfigTests {
    func defaults() -> UserDefaults {
        let name = "orgstar-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func templateRoundTrips() {
        let source = defaults()
        source.set("doom", forKey: "keymap")
        source.set(3, forKey: "optionAsMeta")
        source.set(72, forKey: "fillColumn")
        source.set(false, forKey: "showLineNumbers")
        let text = UserConfig.template(from: source)
        #expect(text.contains("keymap = \"doom\""))
        #expect(text.contains("\nfill-column = 72"))
        #expect(text.contains("org-agenda-start-day = \"-3d\""))
        #expect(text.contains("option-as-meta = \"both\""))
        let target = defaults()
        #expect(UserConfig.apply(text, to: target).isEmpty)
        #expect(target.string(forKey: "keymap") == "doom")
        #expect(target.integer(forKey: "optionAsMeta") == 3)
        #expect(target.integer(forKey: "fillColumn") == 72)
        #expect(target.bool(forKey: "showLineNumbers") == false)
    }

    @Test func problemsAndRemovedLines() {
        let target = defaults()
        target.set(60, forKey: "fillColumn")
        let problems = UserConfig.apply("fill-column = \"wide\"\norg-agenda-start-day = \"soon\"\n[orgstar]\nkeymap = \"vim\"\ncolour = 1\n", to: target)
        #expect(problems.count == 4)
        #expect(target.integer(forKey: "fillColumn") == 60)
        #expect(UserConfig.apply("[orgstar]\n", to: target).isEmpty)
        #expect(target.object(forKey: "fillColumn") == nil)
    }

    @Test func editsKeepCommentsAndOrder() {
        let text = "# mine\n[editor]\nfill-column = 80  # wide\nline-numbers = true\n\n[agenda]\nspan = 10\n"
        #expect(UserConfig.setting(text, section: "editor", key: "fill-column", to: .integer(72))
            == "# mine\n[editor]\nfill-column = 72  # wide\nline-numbers = true\n\n[agenda]\nspan = 10\n")
        #expect(UserConfig.setting(text, section: "editor", key: "show-markup", to: .bool(true))
            == "# mine\n[editor]\nfill-column = 80  # wide\nline-numbers = true\nshow-markup = true\n\n[agenda]\nspan = 10\n")
        #expect(UserConfig.setting(text, section: "capture", key: "global-hotkey", to: .bool(false))
            == "# mine\n[editor]\nfill-column = 80  # wide\nline-numbers = true\n\n[agenda]\nspan = 10\n\n[capture]\nglobal-hotkey = false\n")
        #expect(UserConfig.setting("[general]\nkeymap = \"emacs#1\" # c\n", section: "general", key: "keymap", to: .string("doom"))
            == "[general]\nkeymap = \"doom\"  # c\n")
        #expect(UserConfig.setting("# top\n\n[orgstar]\nsave = \"explicit\"\n", section: "", key: "fill-column", to: .integer(70))
            == "# top\nfill-column = 70\n\n[orgstar]\nsave = \"explicit\"\n")
    }

    @Test func missingSectionsAreAdded() {
        let text = "# mine\nfill-column = 70\n\n[orgstar]\nsave = \"explicit\"\n"
        let completed = UserConfig.addingMissingSections(text, from: defaults())
        #expect(completed.hasPrefix(text))
        #expect(completed.contains("\n[theme]\nfont = \"\"") && !completed.contains("keymap"))
        #expect(UserConfig.addingMissingSections(completed, from: defaults()) == completed)
    }

    @Test func legacyFilesAreRewritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("config.toml")
        try "[editor]\nfill-column = 64\n[general]\nkeymap = \"doom\"\n".write(to: url, atomically: true, encoding: .utf8)
        let store = defaults()
        ConfigSync(url: url, defaults: store).start(watch: false)
        #expect(store.integer(forKey: "fillColumn") == 64)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\nfill-column = 64") && text.contains("keymap = \"doom\"") && !text.contains("[editor]"))
    }

    @Test func legacyNamesMoveInPlace() {
        let text = "# mine\n[editor]\n# my editor\nfill-column = 64  # narrow\n\n[agenda]\nspan = 7\n\n[theme]\nfont-size = 15\n"
        let migrated = UserConfig.migratingLegacyNames(text)
        #expect(migrated == "# mine\nfill-column = 64  # narrow\norg-agenda-span = 7\n[editor]\n# my editor\n\n[theme]\nfont-size = 15\n")
        #expect(!UserConfig.usesLegacyNames(migrated))
        let store = defaults()
        #expect(UserConfig.apply(migrated, to: store).isEmpty)
        #expect(store.integer(forKey: "fillColumn") == 64 && store.integer(forKey: "agendaSpan") == 7 && store.integer(forKey: "themeFontSize") == 15)
        // The new name wins over the old one.
        #expect(UserConfig.migratingLegacyNames("fill-column = 70\n[editor]\nfill-column = 64\n") == "fill-column = 70\n")
    }

    @Test func syncsBothWays() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("config.toml")
        let store = defaults()
        let sync = ConfigSync(url: url, defaults: store)
        sync.start(watch: false)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\nfill-column = 80"))

        store.set(66, forKey: "fillColumn")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("fill-column = 66"))

        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "org-agenda-span = 10", with: "org-agenda-span = 7")
            .replacingOccurrences(of: "org-agenda-start-day = \"-3d\"", with: "org-agenda-start-day = \"+0d\"")
        try text.write(to: url, atomically: true, encoding: .utf8)
        sync.reload()
        #expect(store.integer(forKey: "agendaSpan") == 7)
        #expect(store.integer(forKey: "agendaStartOffset") == 0)
        #expect(sync.problems.isEmpty)
    }
}

@MainActor
struct ThemeConfigTests {
    @Test func themeTablesAreNotSettingsProblems() throws {
        let name = "orgstar-theme-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let problems = UserConfig.apply("[theme]\nfont-size = 15\nlink = \"#123456\"\n[theme.dark]\nlink = \"#654321\"\n", to: defaults)
        #expect(problems.isEmpty)
        #expect(defaults.integer(forKey: "themeFontSize") == 15)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-theme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[theme.light]\nlink = \"#000001\"\ntodo = \"#000002\"\n".write(to: folder.appendingPathComponent("mine.toml"), atomically: true, encoding: .utf8)
        try "[theme]\ntheme-file = \"mine.toml\"\nlink = \"#000003\"\n".write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let sync = ConfigSync(url: folder.appendingPathComponent("config.toml"), defaults: defaults)
        sync.start(watch: false)
        #expect(sync.problems.isEmpty, "\(sync.problems)")
        #expect(sync.theme.light["link"]?.hex == "#000003")
        #expect(sync.theme.light["todo"]?.hex == "#000002")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("default-theme.toml").path))
    }

    @Test func themeFileInASubfolderIsRecognized() throws {
        let name = "orgstar-theme-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-theme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("themes"), withIntermediateDirectories: true)
        try "[theme]\ntheme-file = \"themes/x.toml\"\n".write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let sync = ConfigSync(url: folder.appendingPathComponent("config.toml"), defaults: defaults)
        sync.start(watch: false)
        // The watcher reports paths under the folder with symlinks resolved (/private/var/…).
        let reported = folder.resolvingSymlinksInPath().appendingPathComponent("themes/x.toml")
        #expect(sync.isThemeFile(reported))
        #expect(!sync.isThemeFile(folder.appendingPathComponent("x.toml")))
    }
}
