import Foundation
import OrgCore
import OrgDocument
import OrgIndex
import Testing
@testable import OrgApp

/// A temporary folder that removes itself.
final class Folder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file.standardizedFileURL
    }
}

struct FileTreeTests {
    @Test func foldersFirstThenFiles() {
        let files = ["b.org", "a/z.org", "a/y.org", "c.sync-conflict-1.org", "a2.org"].map {
            FileEntry(path: "/r/" + $0, root: "/r", kind: $0.contains("conflict") ? .conflict : .org)
        }
        let tree = FileTreeNode.build(root: "/r", files: files)
        #expect(tree.children?.map(\.name) == ["a", "a2.org", "b.org", "c.sync-conflict-1.org"])
        #expect(tree.children?[0].children?.map(\.name) == ["y.org", "z.org"])
        #expect(tree.children?[1].children == nil)
    }

    @Test func fuzzyMatching() {
        #expect(FuzzyMatch.score("wn", "work/notes.org") != nil)
        #expect(FuzzyMatch.score("xyz", "work/notes.org") == nil)
        let files = ["work/notes.org", "notes.org", "personal/wine.org"].map { FileEntry(path: "/r/" + $0, root: "/r", kind: .org) }
        #expect(FuzzyMatch.rank("notes", files).map(\.relativePath) == ["notes.org", "work/notes.org"])
        #expect(FuzzyMatch.rank("", files).count == 3)
    }
}

@MainActor
struct WorkspaceModelTests {
    @Test func addSearchRemoveAndPersist() async throws {
        let notes = try Folder()
        let support = try Folder()
        try notes.write("a.org", "* Groceries\nbuy apples\n")
        try notes.write("sub/b.org", "* Taxes\n")
        try notes.write("c.sync-conflict-1.org", "* Taxes copy\n")

        let model = try WorkspaceModel(directory: support.url)
        try await model.addRoot(notes.url)
        #expect(model.files.count == 3)
        #expect(model.search("apples").map(\.title) == ["Groceries"])
        #expect(model.quickOpen("bo").map(\.name) == ["b.org"])
        let root = try #require(model.rootPaths.first)
        #expect(model.tree(forRoot: root).children?.map(\.name) == ["sub", "a.org", "c.sync-conflict-1.org"])

        let reopened = try WorkspaceModel(directory: support.url)
        #expect(reopened.roots.count == 1)
        #expect(reopened.files.count == 3)

        try reopened.removeRoot(path: root)
        #expect(reopened.roots.isEmpty)
        #expect(reopened.files.isEmpty)
        #expect(reopened.search("apples").isEmpty)
    }

    @Test func changedFilesAreReindexed() async throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* Old\n")
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(notes.url)
        try notes.write("a.org", "* New\n")
        await model.filesChanged([file], rescan: [])
        #expect(model.search("new").count == 1)
        #expect(model.changedFile?.path == file.path)
    }
}

@MainActor
struct DocumentSessionTests {
    @Test func openShowAndReload() throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* One\n* Two\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        #expect(session.outline.map(\.title) == ["One", "Two"])

        let location = HeadingLocation(path: file.path, ordinal: 1, title: "Two", start: 6, contentHash: "stale")
        session.show(location)
        #expect(session.revealRequest?.offset == 6)

        try notes.write("a.org", "intro\n* One\n* Two\n")
        session.fileChanged(file.path)
        #expect(session.outline.map(\.start) == [6, 12])
        session.show(location)
        #expect(session.revealRequest?.offset == 12)
    }

    @Test func missingFileReportsAnError() {
        let session = DocumentSession()
        session.open("/nonexistent/a.org")
        #expect(session.lastError != nil)
        #expect(session.document == nil)
    }
}

@MainActor
struct SessionSavingTests {
    let notes: Folder
    let file: URL
    let recovery: FileRecoveryStore
    let session: DocumentSession

    init() throws {
        notes = try Folder()
        file = try notes.write("a.org", "a\nb\nc\n")
        recovery = FileRecoveryStore(directory: notes.url.appendingPathComponent(".recovery"))
        session = DocumentSession(recovery: recovery)
        session.saveMode = .explicit
        session.open(file.path)
    }

    /// Types `text` at `offset`, as the editor would.
    func type(_ text: String, at offset: Int) throws {
        let buffer = StateBuffer(session.document!)
        session.attach(buffer)
        try buffer.update { try $0.apply([TextEdit(range: offset..<offset, replacement: text)], baseRevision: $0.revision) }
        session.bufferChanged()
    }

    var disk: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    @Test func saveWritesAndClearsDirty() throws {
        try type("x", at: 0)
        #expect(session.isDirty)
        #expect(session.save())
        #expect(!session.isDirty)
        #expect(disk == "xa\nb\nc\n")
    }

    @Test func automaticModeSavesAfterTheDelay() async throws {
        session.saveMode = .automatic
        session.autosaveDelay = .milliseconds(10)
        try type("x", at: 0)
        #expect(disk == "a\nb\nc\n")
        await session.autosave?.value
        #expect(disk == "xa\nb\nc\n")
        #expect(!session.isDirty)
    }

    @Test func explicitModeWaitsForSave() throws {
        try type("x", at: 0)
        #expect(session.autosave == nil)
    }

    @Test func externalChangeMergesIntoEdits() throws {
        try type("x", at: 0)
        try notes.write("a.org", "a\nb\nC\n")
        session.fileChanged(file.path)
        #expect(session.document?.text == "xa\nb\nC\n")
        #expect(session.conflict == nil)
        #expect(session.save())
        #expect(disk == "xa\nb\nC\n")
    }

    @Test func conflictKeepMine() throws {
        try type("x", at: 0)
        try notes.write("a.org", "z\nb\nc\n")
        session.fileChanged(file.path)
        #expect(session.conflict != nil)
        #expect(!session.save())
        #expect(disk == "z\nb\nc\n")
        session.keepMine()
        #expect(session.conflict == nil)
        #expect(disk == "xa\nb\nc\n")
        let kept = try recovery.versions(for: file).map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(kept.contains("z\nb\nc\n"))
    }

    @Test func conflictUseDiskVersion() throws {
        try type("x", at: 0)
        try notes.write("a.org", "z\nb\nc\n")
        #expect(!session.save())
        #expect(session.conflict != nil)
        session.useDiskVersion()
        #expect(session.conflict == nil)
        #expect(!session.isDirty)
        #expect(session.document?.text == "z\nb\nc\n")
        let kept = try recovery.versions(for: file).map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(kept.contains("xa\nb\nc\n"))
    }

    @Test func searchSeesUnsavedHeadings() async throws {
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        try type("* Unsaved heading\n", at: 0)
        let overlay = workspace.overlay(path: session.path, document: session.document)
        #expect(workspace.search("unsaved").isEmpty)
        #expect(workspace.search("unsaved", overlay: overlay).map(\.title) == ["Unsaved heading"])
    }
}

@MainActor
struct KeymapLoaderTests {
    @Test func layersTheUserFile() throws {
        let folder = try Folder()
        let missing = KeymapLoader.load(.emacs, userFile: folder.url.appendingPathComponent("none.toml"))
        #expect(missing.keymap == KeymapPreset.emacs.keymap && missing.problems.isEmpty)

        let file = try folder.write("keymap.toml", "[[bind]]\nkeys = \"C-c a\"\ncommand = \"app.palette\"\n[[bind]]\nkeys = \"Q-q\"\ncommand = \"x\"\n")
        let loaded = KeymapLoader.load(.emacs, userFile: file)
        #expect(loaded.keymap.candidates(for: KeySequence.parse("C-c a")!).first?.command == "app.palette")
        #expect(loaded.problems == ["line 4: bad or missing keys"])

        let broken = try folder.write("broken.toml", "keys = \"x")
        #expect(KeymapLoader.load(.mac, userFile: broken).problems == ["line 1: unclosed string"])
    }
}
