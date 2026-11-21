import Foundation
import OrgCore
import Testing
@testable import OrgApp

@MainActor
struct EmacsImportFoldersTests {
    func items(_ paths: [String]) -> [EmacsImport.Item] {
        paths.enumerated().map { EmacsImport.Item(id: $0.offset, name: "org-directory", summary: $0.element, source: "config.el:1", change: .folder($0.element)) }
    }

    func defaults() -> UserDefaults {
        let name = "orgstar-import-folders-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func addsOnlyTheFoldersChosen() async throws {
        let notes = try Folder()
        let picked = try Folder()
        let config = try Folder()
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(notes.url)
        let first = "~/nowhere-\(UUID().uuidString)", second = "~/also-nowhere-\(UUID().uuidString)"
        let all = items([notes.url.path, first, second])
        // The folder already in the sidebar isn't asked for.
        #expect(EmacsImport.foldersToAdd(all, workspace: model) == [first, second])
        let summary = await EmacsImport.apply(all, defaults: defaults(), workspace: model, directory: config.url, chosenFolders: [first: picked.url])
        #expect(Set(model.roots.map(\.path)) == [notes.url.path, picked.url.path])
        #expect(summary.contains("wasn't added"), "\(summary)")
        #expect(!summary.contains(first), "\(summary)")
    }

    @Test func movesAgendaFilesToTheChosenFolders() async throws {
        let picked = try Folder()
        let config = try Folder()
        let model = try WorkspaceModel(directory: nil)
        let mac = "/nowhere-\(UUID().uuidString)/org", other = "/also-nowhere-\(UUID().uuidString)"
        let files = EmacsImport.Item(id: 0, name: "org-agenda-files", summary: "", source: "config.el:1",
                                     change: .setting(key: "org-agenda-files", value: .string("\(mac)/inbox.org\n\(mac)/work/a.org\n\(other)/b.org")))
        let stored = defaults()
        _ = await EmacsImport.apply([files] + items([mac, other]), defaults: stored, workspace: model, directory: config.url, chosenFolders: [mac: picked.url])
        let dir = picked.url.standardizedFileURL.path
        #expect(stored.string(forKey: "agendaFiles") == "\(dir)/inbox.org\n\(dir)/work/a.org")

        let none = defaults()
        let summary = await EmacsImport.apply([files], defaults: none, workspace: model, directory: config.url, chosenFolders: [:])
        #expect(none.string(forKey: "agendaFiles") == nil)
        #expect(summary.contains("org-agenda-files wasn't set"), "\(summary)")

        // A config.toml the Mac reads too keeps the Mac's paths beside the device's.
        let shared = EmacsImport.agendaFiles("\(mac)/inbox.org\n\(other)/b.org", chosenFolders: [mac: picked.url], keepingOriginals: true)
        #expect(shared == "\(mac)/inbox.org\n\(dir)/inbox.org\n\(other)/b.org")
    }

    @Test func withoutChosenFoldersAddsWhatsWritten() async throws {
        let notes = try Folder()
        let config = try Folder()
        let model = try WorkspaceModel(directory: nil)
        let summary = await EmacsImport.apply(items([notes.url.path, "/nowhere-\(UUID().uuidString)"]), defaults: defaults(), workspace: model, directory: config.url)
        #expect(model.roots.map(\.path) == [notes.url.path])
        #expect(summary.contains("doesn't exist"), "\(summary)")
    }

    @Test func readsDoomDefaultsFromAChosenInstall() throws {
        let install = try Folder()
        let user = try Folder()
        try user.write("init.el", "(doom! :lang (org +pretty))")
        try user.write("config.el", "(setq org-directory \"~/notes/\")")
        #expect(EmacsImport.doomDefaultFiles(in: install.url).isEmpty)
        try install.write("lisp/doom.el", ";; doom")
        try install.write("lisp/doom-emacs.el", "(setq fill-column 80)")
        try install.write("modules/lang/org/config.el", "(after! org (setq org-log-done 'time))")
        let files = EmacsImport.doomDefaultFiles(in: install.url)
        #expect(files.map(\.lastPathComponent) == ["config.el", "doom-emacs.el"])

        let without = EmacsImport.scan(EmacsImport.files(in: user.url), doomDefaults: [])
        #expect(without.isDoom && !without.doomDefaultsRead)
        let with = EmacsImport.scan(EmacsImport.files(in: user.url), doomDefaults: files)
        #expect(with.isDoom && with.doomDefaultsRead)
        #expect(with.items.contains { if case .setting(let key, _) = $0.change { key == "org-log-done" } else { false } })
    }

    @Test func doomInstallsStartWithTheHomeFolders() {
        let home = URL(fileURLWithPath: OrgPaths.home)
        #expect(EmacsImport.doomInstallLocations().suffix(2) == [".config/emacs", ".emacs.d"].map { home.appendingPathComponent($0) })
        #expect(EmacsImport.pickerLocation() == EmacsImport.defaultLocations().first ?? home)
    }
}
