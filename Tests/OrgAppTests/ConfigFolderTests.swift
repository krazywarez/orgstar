import Foundation
import OrgCore
import Testing
@testable import OrgApp

@MainActor
struct ConfigFolderTests {
    func defaults() -> UserDefaults {
        let name = "orgstar-config-folder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-config-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func chosenFolderResolves() throws {
        let store = defaults()
        let url = try folder()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ConfigFolder.resolve(defaults: store) == nil)
        ConfigFolder.set(url, defaults: store)
        #expect(store.data(forKey: ConfigFolder.bookmarkKey) != nil)
        let resolved = try #require(ConfigFolder.resolve(defaults: store))
        #expect(resolved.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path)
        ConfigFolder.clear(defaults: store)
        #expect(ConfigFolder.resolve(defaults: store) == nil)
    }

    @Test func aFolderWithoutABookmarkIsNotKept() {
        let store = defaults()
        #expect(!ConfigFolder.set(URL(fileURLWithPath: "/nowhere-\(UUID().uuidString)"), defaults: store))
        #expect(store.data(forKey: ConfigFolder.bookmarkKey) == nil)
    }

    /// iOS keeps its folder under the key it always used.
    @Test func bookmarkKeyIsUnchanged() {
        #expect(ConfigFolder.bookmarkKey == "configFolderBookmark")
    }

    @Test func suggestedIsInTheRealHome() {
        #expect(ConfigFolder.suggested.path == OrgPaths.home + "/.config/orgstar")
    }

    @Test func movingAppliesTheNewFolder() throws {
        let first = try folder()
        let second = try folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try "fill-column = 64\n".write(to: first.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "fill-column = 72\n".write(to: second.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let store = defaults()
        let sync = ConfigSync(url: first.appendingPathComponent("config.toml"), defaults: store)
        sync.start(watch: false)
        #expect(store.integer(forKey: "fillColumn") == 64)
        sync.move(to: second.appendingPathComponent("config.toml"))
        #expect(store.integer(forKey: "fillColumn") == 72)
        #expect(sync.changedFile?.name == "keymap.toml")
        // Changes made in the app go into the new file only.
        store.set(80, forKey: "fillColumn")
        sync.writeBack()
        #expect(try String(contentsOf: second.appendingPathComponent("config.toml"), encoding: .utf8).contains("fill-column = 80"))
        let old = try String(contentsOf: first.appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(old.contains("fill-column = 64") && !old.contains("fill-column = 80"))
    }

    @Test func movingToAnEmptyFolderWritesTheCurrentSettings() throws {
        let first = try folder()
        let second = try folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try "fill-column = 64\n".write(to: first.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let store = defaults()
        let sync = ConfigSync(url: first.appendingPathComponent("config.toml"), defaults: store)
        sync.start(watch: false)
        sync.move(to: second.appendingPathComponent("config.toml"))
        #expect(try String(contentsOf: second.appendingPathComponent("config.toml"), encoding: .utf8).contains("fill-column = 64"))
    }

    @Test func movingBeforeStartDoesNothing() throws {
        let first = try folder()
        let second = try folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let sync = ConfigSync(url: first.appendingPathComponent("config.toml"), defaults: defaults())
        sync.move(to: second.appendingPathComponent("config.toml"))
        #expect(!FileManager.default.fileExists(atPath: second.appendingPathComponent("config.toml").path))
    }
}
