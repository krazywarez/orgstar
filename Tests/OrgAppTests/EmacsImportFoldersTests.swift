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
