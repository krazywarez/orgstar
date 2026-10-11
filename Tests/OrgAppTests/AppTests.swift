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

    @Test func aMovedFolderLeavesNoOldRows() async throws {
        let parent = try Folder()
        let original = parent.url.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try "* Plumber\n".write(to: original.appendingPathComponent("a.org"), atomically: true, encoding: .utf8)
        let data = parent.url.appendingPathComponent("data")
        let model = try WorkspaceModel(directory: data)
        try await model.addRoot(original)
        #expect(model.search("plumber").count == 1)

        let moved = parent.url.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: original, to: moved)
        let reopened = try WorkspaceModel(directory: data)
        await reopened.refresh()
        let found = reopened.search("plumber").map(\.path)
        #expect(found.count == 1 && found[0].hasSuffix("/moved/a.org"), "\(found)")
        // Adding it again, under its new path, adds nothing.
        try await reopened.addRoot(moved)
        #expect(reopened.roots.count == 1)
    }

    @Test func listsDownloadsInTheTree() {
        let files = [FileEntry(path: "/r/a.org", root: "/r", kind: .org)]
        let tree = FileTreeNode.build(root: "/r", files: files, downloading: ["/r/b.org", "/r/sub/c.org"])
        #expect(tree.children?.map(\.name) == ["sub", "a.org", "b.org"])
        #expect(tree.children?[2].isDownloading == true && tree.children?[2].file == nil)
        #expect(tree.children?[0].children?.map(\.name) == ["c.org"])
    }

    @Test func findsBacklinks() async throws {
        let notes = try Folder()
        try notes.write("a.org", "* Sink\n:PROPERTIES:\n:ID: s-1\n:CUSTOM_ID: sink\n:END:\nsee [[*Taps]]\n* Taps\n")
        try notes.write("b.org", "* Plumbing\n[[id:s-1][the sink]] and [[file:a.org]]\n* Other\n[[file:a.org::#sink]] [[https://x.org]]\n")
        // Links before the first heading come from the file itself.
        try notes.write("c.org", "#+TITLE: C\nAbout [[file:a.org::*Sink]] and [[file:a.org]].\n* Later\n")
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(notes.url)
        let a = try #require(model.files.first { $0.path.hasSuffix("/a.org") }).path
        let c = try #require(model.files.first { $0.path.hasSuffix("/c.org") }).path
        let sink = Backlinks.Target(path: a, title: "Sink", id: "s-1", customID: "sink")
        #expect(model.backlinks(to: sink).map(\.title) == ["Plumbing", "Other", "c.org"])
        #expect(model.backlinks(to: Backlinks.Target(path: a)).map(\.title) == ["Plumbing", "c.org"])
        #expect(model.backlinks(to: Backlinks.Target(path: a, title: "Taps")).map(\.title) == ["Sink"])
        #expect(model.backlinks(to: sink, excluding: 0).map(\.title) == ["Plumbing", "Other", "c.org"])
        let fromC = try #require(model.backlinks(to: sink).last)
        #expect(fromC == .file(c, contentHash: fromC.contentHash))
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.show(fromC)
        #expect(session.path == c && session.revealRequest?.offset == 0)
    }

    @Test func createRenameAndTrashFiles() async throws {
        let notes = try Folder()
        try notes.write("a.org", "* Alpha\n")
        let model = try WorkspaceModel(directory: nil)
        model.trasher = { try FileManager.default.removeItem(at: $0) }
        try await model.addRoot(notes.url)
        let root = try #require(model.rootPaths.first)

        let created = try await model.createFile(named: "projects/plan", in: root)
        #expect(created == root + "/projects/plan.org")
        #expect(model.files.map(\.path).contains(created))
        await #expect(throws: WorkspaceModel.FileError.self) { try await model.createFile(named: "projects/plan.org", in: root) }
        await #expect(throws: WorkspaceModel.FileError.self) { try await model.createFile(named: "../escape", in: root) }

        let renamed = try await model.rename(created, to: "roadmap.org")
        #expect(model.files.map(\.path).contains(renamed) && !model.files.map(\.path).contains(created))
        let folder = try await model.rename(root + "/projects", to: "work")
        #expect(model.files.map(\.path).contains(folder + "/roadmap.org"))

        try await model.trash(folder + "/roadmap.org")
        #expect(!FileManager.default.fileExists(atPath: folder + "/roadmap.org"))
        #expect(!model.files.map(\.path).contains(folder + "/roadmap.org"))
        #expect(model.search("alpha").count == 1)
    }

    /// Watching starts with no folders (a first launch); a folder added afterwards is
    /// watched.
    @Test func foldersAddedLaterAreWatched() async throws {
        let notes = try Folder()
        let model = try WorkspaceModel(directory: nil)
        model.startWatching()
        try await model.addRoot(notes.url)
        let file = try notes.write("new.org", "* Fresh heading\n")
        var found = false
        for _ in 0..<40 where !found {
            try await Task.sleep(for: .milliseconds(100))
            found = model.files.contains { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == file.resolvingSymlinksInPath() }
        }
        #expect(found)
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

    @Test func sameFileByAnotherPathSharesItsBuffer() throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* One\n")
        let link = notes.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        session.open(link.appendingPathComponent("a.org").path)
        #expect(session.openPaths == [file.path])
        #expect(session.path == file.path)
    }

    @Test func buffersOfTheSameNameShowTheirFolders() throws {
        let notes = try Folder()
        let a = try notes.write("x/blog/index.org", "a\n")
        let b = try notes.write("y/blog/index.org", "b\n")
        let c = try notes.write("y/other.org", "c\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(a.path)
        #expect(session.bufferName(a.path) == "index.org")
        session.open(b.path)
        session.open(c.path)
        #expect(session.bufferName(a.path) == "index.org<x/blog>")
        #expect(session.bufferName(b.path) == "index.org<y/blog>")
        #expect(session.bufferName(c.path) == "other.org")
    }

    @Test func openReadsSetupFiles() throws {
        let notes = try Folder()
        try notes.write("setup.org", "#+TODO: NEXT | DONE\n")
        let file = try notes.write("a.org", "#+SETUPFILE: setup.org\n* NEXT One\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        #expect(session.document?.tree.settings.todoKeywordNames.contains("NEXT") == true)
    }


    @Test func keywordCtrlCCtrlCRereadsSetupFiles() throws {
        let notes = try Folder()
        try notes.write("setup.org", "#+TODO: NEXT | DONE\n")
        let file = try notes.write("a.org", "#+SETUPFILE: setup.org\n* WAIT One\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        #expect(session.document?.tree.settings.todoKeywordNames.contains("WAIT") == false)
        try notes.write("setup.org", "#+TODO: NEXT WAIT | DONE\n")
        let text = session.document!.text
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .commit(let result) = CtrlCCtrlC().run(in: context) else { Issue.record("no commit"); return }
        #expect(result.effects.contains(.refreshSetup))
        session.refreshSetup()
        #expect(session.document?.tree.settings.todoKeywordNames.contains("WAIT") == true)
        #expect(session.document?.isDirty == false)
    }

    @Test func reloadingFromDiskReadsSetupFilesAgain() throws {
        let notes = try Folder()
        try notes.write("setup.org", "#+TODO: NEXT | DONE\n")
        let file = try notes.write("a.org", "* WAIT One\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        try notes.write("a.org", "#+SETUPFILE: setup.org\n* WAIT One\n")
        try notes.write("setup.org", "#+TODO: WAIT | DONE\n")
        session.fileChanged(file.path)
        #expect(session.document?.tree.settings.todoKeywordNames.contains("WAIT") == true)
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

@MainActor
struct MoveSubtreeTests {
    @Test func refileWithinAndAcrossFiles() async throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* one\nbody\n* two\n")
        let other = try notes.write("b.org", "* inbox\n")
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.saveMode = .explicit
        session.open(file.path)
        let targets = workspace.refileTargets(openPath: session.path, document: session.document)
        #expect(targets.map(\.label) == ["a.org", "a.org/one", "a.org/two", "b.org", "b.org/inbox"])

        #expect(session.refile(to: targets[2]) == "Refiled to a.org/two")
        #expect(session.document?.text == "* two\n** one\nbody\n")

        let inbox = try #require(workspace.refileTargets(openPath: session.path, document: session.document).first { $0.label == "b.org/inbox" })
        StateBufferCaret.set(session, 6)
        #expect(session.refile(to: inbox) == "Refiled to b.org/inbox")
        #expect(try String(contentsOf: other, encoding: .utf8) == "* inbox\n** one\nbody\n")
        #expect(session.document?.text == "* two\n")
    }

    @Test func archiveToTheArchiveFile() throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* done\n* keep\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.saveMode = .explicit
        session.open(file.path)
        #expect(session.archive(now: Date(timeIntervalSince1970: 0)) == "Archived to a.org_archive")
        #expect(session.document?.text == "* keep\n")
        let archived = try String(contentsOf: notes.url.appendingPathComponent("a.org_archive"), encoding: .utf8)
        #expect(archived.contains("* done\n:PROPERTIES:\n:ARCHIVE_TIME:"))
    }
}

@MainActor
struct AgendaActionTests {
    /// From the agenda: entries in files that aren't open move and archive on disk, and the
    /// current buffer stays as it was.
    @Test func refileAndArchiveFromAnEntry() async throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* one\nbody\n* two\n* three\n")
        let other = try notes.write("b.org", "* inbox\n")
        let shown = try notes.write("c.org", "* shown\n")
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.saveMode = .explicit
        session.open(shown.path)

        let inbox = try #require(workspace.refileTargets(openPath: nil, document: nil).first { $0.label == "b.org/inbox" })
        #expect(session.refile(to: inbox, from: (file.path, 0)) == "Refiled to b.org/inbox")
        #expect(try String(contentsOf: other, encoding: .utf8) == "* inbox\n** one\nbody\n")
        #expect(try String(contentsOf: file, encoding: .utf8) == "* two\n* three\n")

        let text = try String(contentsOf: file, encoding: .utf8)
        let two = try #require(workspace.refileTargets(openPath: file.path, document: DocumentState(bytes: [UInt8](text.utf8))).first { $0.label == "a.org/two" })
        #expect(session.refile(to: two, from: (file.path, 6)) == "Refiled to a.org/two")
        #expect(try String(contentsOf: file, encoding: .utf8) == "* two\n** three\n")

        #expect(session.archive(from: (file.path, 0), now: Date(timeIntervalSince1970: 0)) == "Archived to a.org_archive")
        #expect(try String(contentsOf: file, encoding: .utf8) == "")
        #expect(session.path == shown.path && session.document?.text == "* shown\n")
    }

    @Test func locatesMovedHeadings() throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* new\n* task\n* other\n* task\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        #expect(session.locateHeading(path: file.path, line: "* task", near: 0) == 6)
        #expect(session.locateHeading(path: file.path, line: "* task", near: 20) == 21)
        #expect(session.locateHeading(path: file.path, line: "* other", near: 14) == 13)
        #expect(session.locateHeading(path: file.path, line: "* gone", near: 0) == nil)
    }
}

@MainActor
struct MoveIntoOpenBufferTests {
    /// A target open with unsaved edits above its heading takes the subtree in its buffer,
    /// under the right heading, and the disk keeps the saved text.
    @Test func refileIntoAnOpenBuffer() async throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* task\nbody\n")
        let other = try notes.write("b.org", "* inbox\n* projects\n")
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.saveMode = .explicit
        session.open(other.path)
        let projects = try #require(workspace.refileTargets(openPath: nil, document: nil).first { $0.label == "b.org/projects" })
        _ = session.perform(InsertText(text: "* new\n"), path: other.path, at: 0, expect: nil)
        session.open(file.path)
        #expect(session.refile(to: projects) == "Refiled to b.org/projects")
        #expect(session.document?.text == "")
        #expect(session.openDocuments.first { $0.path == other.path }?.document.text == "* new\n* inbox\n* projects\n** task\nbody\n")
        #expect(try String(contentsOf: other, encoding: .utf8) == "* inbox\n* projects\n")
    }

    @Test func archiveIntoAnOpenBuffer() throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* done\n* keep\n")
        let archive = try notes.write("a.org_archive", "* old\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.saveMode = .explicit
        session.open(archive.path)
        session.open(file.path)
        #expect(session.archive(now: Date(timeIntervalSince1970: 0)) == "Archived to a.org_archive")
        #expect(session.document?.text == "* keep\n")
        let text = try #require(session.openDocuments.first { $0.path == archive.path }?.document.text)
        #expect(text.hasPrefix("* old\n") && text.contains("* done\n:PROPERTIES:\n:ARCHIVE_TIME:"))
        #expect(try String(contentsOf: archive, encoding: .utf8) == "* old\n")
    }
}

/// Inserts text at the caret, for tests.
struct InsertText: OrgCommand {
    let text: String
    var id: String { "test.insert" }
    var title: String { "Insert" }
    func applies(in context: EditContext) -> Bool { true }
    func run(in context: EditContext) -> CommandStep {
        .commit(EditResult(baseRevision: context.revision, edits: [TextEdit(range: context.caret..<context.caret, replacement: text)]))
    }
}

/// Moves the caret of a session's `StateBuffer`, as clicking in the editor would.
@MainActor
enum StateBufferCaret {
    static func set(_ session: DocumentSession, _ offset: Int) {
        let buffer = StateBuffer(session.document!)
        buffer.selection = [offset..<offset]
        session.attach(buffer)
    }
}

@MainActor
struct AgendaModelTests {
    @Test func openBuffersFollowTheirText() async throws {
        let notes = try Folder()
        let file = try notes.write("a.org", "* TODO One\n")
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(notes.url)
        let agenda = AgendaModel(workspace: model)
        agenda.mode = .todo(keywords: nil)
        for text in ["* TODO One\n", "* TODO Two\n", "* TODO One\n", "* TODO Two\n"] {
            await agenda.refresh(open: [file.path: text])
            #expect(agenda.list.map(\.text) == [String(text.dropFirst(2).dropLast())])
        }
        await agenda.refresh(open: [:])
        #expect(agenda.list.map(\.text) == ["TODO One"])
    }

    @Test func entriesKnowTheirDoneKeyword() async throws {
        let notes = try Folder()
        try notes.write("setup.org", "#+TODO: NEXT | FINISHED\n")
        try notes.write("a.org", "#+SETUPFILE: setup.org\n* NEXT One\n")
        let plain = try notes.write("b.org", "* WAIT Two\n")
        let model = try WorkspaceModel(directory: nil)
        model.settings = .with(todoKeywords: try #require(OrgSettings.default.withTodoKeywords("WAIT | OK")))
        try await model.addRoot(notes.url)
        let agenda = AgendaModel(workspace: model)
        agenda.mode = .todo(keywords: nil)
        await agenda.refresh(open: [:])
        #expect(Dictionary(uniqueKeysWithValues: agenda.list.map { ($0.todo ?? "", $0.doneKeyword) }) == ["NEXT": "FINISHED", "WAIT": "OK"])
        await agenda.refresh(open: [plain.path: "#+TODO: WAIT | GONE\n* WAIT Two\n"])
        #expect(agenda.list.first { $0.todo == "WAIT" }?.doneKeyword == "GONE")
    }

    @Test func topLevelFilesAndTheOpenBuffer() async throws {
        let notes = try Folder()
        try notes.write("a.org", "* TODO Pay rent\nSCHEDULED: <2026-10-05 Mon>\n")
        try notes.write("sub/b.org", "* Hidden <2026-10-05 Mon>\n")
        try notes.write("old.org_archive", "* Archived <2026-10-05 Mon>\n")
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(notes.url)
        let agenda = AgendaModel(workspace: model)
        agenda.startOffset = -3
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))

        await agenda.refresh(open: [:], now: now, calendar: utc)
        #expect(agenda.days.count == 10)
        #expect(agenda.days[3].isToday)
        #expect(agenda.days[3].items.map(\.text) == ["TODO Pay rent"])

        agenda.includeSubfolders = true
        await agenda.refresh(open: [:], now: now, calendar: utc)
        #expect(agenda.days[3].items.map(\.text) == ["TODO Pay rent", "Hidden "])

        let path = try #require(agenda.files.first { $0.hasSuffix("/a.org") })
        await agenda.refresh(open: [path: "* DONE Pay rent\nSCHEDULED: <2026-10-05 Mon>\n"], now: now, calendar: utc)
        #expect(agenda.days[3].items.first?.text == "DONE Pay rent")

        agenda.shift(forward: true, now: now, calendar: utc)
        await agenda.refresh(open: [:], now: now, calendar: utc)
        #expect(agenda.days.first?.day == Days.absolute(year: 2026, month: 10, day: 12))

        // org-agenda-start-on-weekday: a week starts on Monday by default, from a Wednesday.
        let wednesday = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9)))
        agenda.showToday()
        agenda.span = 7
        agenda.startOffset = 0
        await agenda.refresh(open: [:], now: wednesday, calendar: utc)
        #expect(agenda.days.first?.day == Days.absolute(year: 2026, month: 10, day: 5))
        agenda.startOnWeekday = 0
        await agenda.refresh(open: [:], now: wednesday, calendar: utc)
        #expect(agenda.days.first?.day == Days.absolute(year: 2026, month: 10, day: 4))
        agenda.shift(forward: true, now: wednesday, calendar: utc)
        await agenda.refresh(open: [:], now: wednesday, calendar: utc)
        #expect(agenda.days.first?.day == Days.absolute(year: 2026, month: 10, day: 11))
        agenda.showToday()
        agenda.startOnWeekday = nil
        await agenda.refresh(open: [:], now: wednesday, calendar: utc)
        #expect(agenda.days.first?.day == Days.absolute(year: 2026, month: 10, day: 7))
        agenda.startOnWeekday = 1
        agenda.span = 10
        await agenda.refresh(open: [:], now: wednesday, calendar: utc)
        #expect(agenda.days.first?.day == Days.absolute(year: 2026, month: 10, day: 7))
    }
}

@MainActor
struct AgendaCommandTests {
    @Test func loadsViews() throws {
        let folder = try Folder()
        let file = try folder.write("views.toml", """
        [[view]]
        name = "Work"
        type = "match"
        match = "+work"
        [[view]]
        name = "Week"
        span = 7
        start = -1
        [[view]]
        name = "Waiting"
        type = "todo"
        keywords = "WAIT|HOLD"
        [[view]]
        name = "Broken"
        type = "match"
        """)
        let loaded = AgendaViewLoader.load(userFile: file)
        #expect(loaded.views.map(\.name) == ["Agenda", "TODO List", "Work", "Week", "Waiting"])
        #expect(loaded.views[2].mode == .match("+work", todoOnly: false))
        #expect(loaded.views[3].mode == .agenda(span: 7, startOffset: -1))
        #expect(loaded.views[4].mode == .todo(keywords: "WAIT|HOLD"))
        #expect(loaded.problems == ["views.toml line 13: Broken needs a match"])
    }

    @Test func todoListMode() async throws {
        let notes = try Folder()
        try notes.write("a.org", "* TODO One :work:\n* DONE Two\n* TODO Three\n")
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(notes.url)
        let agenda = AgendaModel(workspace: model)
        agenda.mode = .todo(keywords: nil)
        await agenda.refresh(open: [:])
        #expect(agenda.list.map(\.text) == ["TODO One", "TODO Three"])
        agenda.mode = .match("work", todoOnly: false)
        await agenda.refresh(open: [:])
        #expect(agenda.list.map(\.text) == ["TODO One"])
    }

    @Test func runsCommandsOnClosedAndOpenFiles() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* TODO One\n* TODO Two\n")
        let b = try notes.write("b.org", "* TODO Three\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(a.path)

        // A closed file is changed on disk.
        let closed = session.perform(TodoCycle(), path: b.path, at: 0, expect: (0, "* TODO Three"))
        guard case .commit = closed else { Issue.record("\(closed)"); return }
        #expect(try String(contentsOf: b, encoding: .utf8) == "* DONE Three\n")

        // The open file changes in its buffer.
        let open = session.perform(TodoCycle(), path: a.path, at: 11, expect: (11, "* TODO Two"))
        guard case .commit = open else { Issue.record("\(open)"); return }
        #expect(session.document?.text == "* TODO One\n* DONE Two\n")

        // A heading that moved is refused.
        let stale = session.perform(TodoCycle(), path: b.path, at: 0, expect: (0, "* TODO Three"))
        guard case .failed = stale else { Issue.record("\(stale)"); return }
        #expect(try String(contentsOf: b, encoding: .utf8) == "* DONE Three\n")
    }
}

final class FakeReminderCenter: ReminderCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = ["someone.else"]
    var authorized = true
    private(set) var added: [String] = []

    func authorize() async -> Bool { authorized }
    func pendingIDs() async -> [String] { lock.withLock { pending } }
    var delivered: [String] = []
    func deliveredIDs() async -> [String] { lock.withLock { delivered } }
    /// The system showing a notification: no longer pending.
    func fire(_ id: String, keep: Bool) {
        lock.withLock {
            pending.removeAll { $0 == id }
            if keep { delivered.append(id) }
        }
    }
    func add(_ reminder: Reminder) async throws {
        lock.withLock {
            pending.append(reminder.id)
            added.append(reminder.id)
        }
    }
    func remove(_ ids: [String]) { lock.withLock { pending.removeAll { ids.contains($0) } } }
    var ids: [String] { lock.withLock { pending } }
}

@MainActor
struct ReminderSchedulerTests {
    func reminder(_ id: String, _ minutes: Double) -> Reminder {
        let date = Date(timeIntervalSince1970: 1_000_000 + minutes * 60)
        return Reminder(id: "orgstar.\(id)", fireDate: date, eventDate: date.addingTimeInterval(720), title: id, body: "", path: "/a.org", offset: 0)
    }

    @Test func reconciles() async {
        let center = FakeReminderCenter()
        let scheduler = ReminderScheduler(center: center)
        await scheduler.reconcile([reminder("a", 1), reminder("b", 2)])
        #expect(center.ids == ["someone.else", "orgstar.a", "orgstar.b"])
        #expect(scheduler.scheduledThrough == reminder("b", 2).eventDate)

        await scheduler.reconcile([reminder("b", 2), reminder("c", 3)])
        #expect(center.ids == ["someone.else", "orgstar.b", "orgstar.c"])
        #expect(center.added == ["orgstar.a", "orgstar.b", "orgstar.c"])

        await scheduler.clear()
        #expect(center.ids == ["someone.else"])
        #expect(scheduler.scheduledThrough == nil)

        // Fired reminders aren't set again, whether or not they're still in Notification Center.
        await scheduler.reconcile([reminder("e", 5), reminder("f", 6)])
        center.fire("orgstar.e", keep: false)
        await scheduler.reconcile([reminder("e", 5), reminder("f", 6)])
        #expect(center.added.filter { $0 == "orgstar.e" }.count == 1)
        let relaunched = ReminderScheduler(center: center)
        center.fire("orgstar.f", keep: true)
        await relaunched.reconcile([reminder("f", 6)])
        #expect(center.added.filter { $0 == "orgstar.f" }.count == 1)
        await scheduler.clear()

        center.authorized = false
        await scheduler.reconcile([reminder("d", 4)])
        #expect(!scheduler.isAuthorized)
        #expect(center.ids == ["someone.else"])
    }
}

@MainActor
struct EmacsFallbackTests {
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func recalculatesTablesNativeCodeCannot() async throws {
        let notes = try Folder()
        let file = try notes.write("t.org", "* Prices\n| item | n | twice |\n|------+---+-------|\n| x | a | |\n| y | 2 | |\n#+TBLFM: $3=$2*2\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(TableRecalculate(all: true), path: file.path, at: 50, expect: nil)
        guard case .external(.emacsTable(let table, let point, let form, let reason, let lisp)) = step else {
            Issue.record("\(step)")
            return
        }
        #expect(reason == "non-numeric field a")
        #expect(!lisp)
        let message = await session.recalculateInEmacs(table: table, point: point, form: form)
        #expect(message == "Recalculated in Emacs")
        #expect(session.document?.text == "* Prices\n| item | n | twice |\n|------+---+-------|\n| x    | a | 2 a   |\n| y    | 2 | 4     |\n#+TBLFM: $3=$2*2\n")
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func cancelingARecalculationLeavesTheTable() async throws {
        let notes = try Folder()
        let text = "| n | twice |\n|---+-------|\n| a |       |\n#+TBLFM: $2=$1*2\n"
        let file = try notes.write("t.org", text)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(TableRecalculate(all: true), path: file.path, at: 2, expect: nil)
        guard case .external(.emacsTable(let table, let point, let form, _, _)) = step else {
            Issue.record("\(step)")
            return
        }
        let task = Task { await session.recalculateInEmacs(table: table, point: point, form: form) }
        task.cancel()
        #expect(await task.value == "Recalculation canceled")
        #expect(session.document?.text == text)
    }
}

@MainActor
struct BabelSessionTests {
    @Test func runsBlocksAndWritesResults() async throws {
        let notes = try Folder()
        let file = try notes.write("b.org", "#+begin_src sh\necho answer\necho \"$((6 * 7))\"\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(ExecuteSrcBlock(), path: file.path, at: 3, expect: nil)
        guard case .external(.babel(let job)) = step else {
            Issue.record("\(step)")
            return
        }
        #expect(await session.runBabel(job) == "Code block evaluation complete.")
        // A column that is half numbers is right-aligned, as org-table-align does.
        #expect(session.document?.text == "#+begin_src sh\necho answer\necho \"$((6 * 7))\"\n#+end_src\n\n#+RESULTS:\n| answer |\n|     42 |\n")
    }
}

@MainActor
struct BabelErrorTests {
    func job(_ session: DocumentSession, _ path: String) throws -> BabelJob {
        guard case .external(.babel(let job)) = session.perform(ExecuteSrcBlock(), path: path, at: 3, expect: nil) else {
            throw CancellationError()
        }
        return job
    }

    /// Like `org-babel-eval`: the results go in, and the error output and status are shown.
    @Test func reportsErrorsAndStillInsertsResults() async throws {
        let notes = try Folder()
        let file = try notes.write("e.org", "#+begin_src sh\necho out\necho oops >&2\nexit 3\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        #expect(await session.runBabel(try job(session, file.path)) == "Exited with status 3: oops")
        #expect(session.document?.text.hasSuffix("#+RESULTS:\n: out\n") == true)
    }

    @Test func cancelsARunningBlock() async throws {
        let notes = try Folder()
        let file = try notes.write("s.org", "#+begin_src sh\nsleep 20\necho late\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let start = ContinuousClock.now
        var message: String?
        session.startBabel(try job(session, file.path)) { message = $0 }
        #expect(session.isRunningBabel)
        try await Task.sleep(for: .milliseconds(200))
        session.cancelBabel()
        while message == nil, ContinuousClock.now - start < .seconds(5) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(message == "Code block canceled.")
        #expect(!session.isRunningBabel)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(session.document?.text.contains("#+RESULTS:") == false)
    }
}

struct EmacsExportTests {
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportsBesideTheFile() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "#+TITLE: On disk\n")
        // The buffer's text is exported, not the file's.
        let written = try await EmacsRunner.export(text: "#+TITLE: In the buffer\n\n* Heading\nBody.\n", path: file.path, function: "org-ascii-export-to-ascii")
        #expect(URL(fileURLWithPath: written).lastPathComponent == "doc.txt")
        let text = try String(contentsOfFile: written, encoding: .utf8)
        #expect(text.uppercased().contains("IN THE BUFFER") && text.contains("Body."), "\(text)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "#+TITLE: On disk\n")
    }

    /// The dispatcher's `C-s` and `C-b`: the subtree at point alone, its EXPORT_FILE_NAME used.
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportsTheSubtreeBodyOnly() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let text = "#+TITLE: Doc\n* Ünï\nFirst.\n* Second\n:PROPERTIES:\n:EXPORT_FILE_NAME: second\n:END:\nOnly this.\n"
        let point = (text as NSString).substring(to: (text as NSString).range(of: "Only").location).unicodeScalars.count + 1
        let written = try await EmacsRunner.export(text: text, path: file.path, function: "org-ascii-export-to-ascii", subtree: point, bodyOnly: true)
        #expect(URL(fileURLWithPath: written).lastPathComponent == "second.txt")
        let out = try String(contentsOfFile: written, encoding: .utf8)
        #expect(out.contains("Only this.") && !out.contains("First.") && !out.uppercased().contains("DOC"), "\(out)")
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportUsesBabelPath() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let function = #"(lambda () (with-temp-file "path.txt" (insert (getenv "PATH"))) "path.txt")"#
        let written = try await EmacsRunner.export(text: "", path: file.path, function: function)
        #expect(try String(contentsOfFile: written, encoding: .utf8) == BabelRunner.environment["PATH"])
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func cancellingStopsTheExport() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let pidFile = notes.url.appendingPathComponent("pid")
        let function = #"(lambda () (with-temp-file "pid" (insert (number-to-string (emacs-pid)))) (sleep-for 60) "x")"#
        let export = Task { try await EmacsRunner.export(text: "", path: file.path, function: function) }
        var pid: pid_t?
        for _ in 0..<200 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
        }
        let started = try #require(pid)
        export.cancel()
        await #expect(throws: CancellationError.self) { try await export.value }
        var alive = true
        for _ in 0..<100 where alive {
            alive = kill(started, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive)
    }
}

@MainActor
struct CaptureAppTests {
    @Test func loadsTemplates() throws {
        let folder = try Folder()
        let file = try folder.write("capture.toml", """
        [[template]]
        key = "w"
        name = "Work"
        file = "work.org"
        olp = "Projects/Work"
        template = "* TODO %?\\n%a"
        [[template]]
        key = "j"
        type = "plain"
        file = "~/journal.org"
        template = "%U %?"
        prepend = true
        """)
        let loaded = CaptureTemplates.load(userFile: file)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.templates.map(\.key) == ["w", "j"])
        #expect(loaded.templates[0].target == .outline(file: "work.org", path: ["Projects", "Work"]))
        #expect(loaded.templates[0].template == "* TODO %?\n%a")
        #expect(loaded.templates[1].kind == .plain && loaded.templates[1].prepend)
        try """
        [[template]]
        key = "d"
        file = "journal.org"
        datetree = true
        olp = "Journal"
        tree-type = "month"
        template = "* %?"
        empty-lines-after = 1
        jump-to-captured = true
        [[template]]
        key = "i"
        id = "abc"
        template = "* %?"
        clock-in = true
        clock-resume = true
        [[template]]
        key = "k"
        clock = true
        type = "item"
        template = "%?"
        immediate-finish = true
        """.write(to: file, atomically: true, encoding: .utf8)
        let targets = CaptureTemplates.load(userFile: file)
        #expect(targets.problems.isEmpty)
        #expect(targets.templates.map(\.target) == [.datetree(file: "journal.org", path: ["Journal"], tree: .month), .id("abc"), .clock])
        #expect(targets.templates[0].options == .init(emptyLinesAfter: 1, jumpToCaptured: true))
        #expect(targets.templates[1].options == .init(clockIn: true, clockResume: true))
        #expect(targets.templates[2].options.immediateFinish)
        #expect(CaptureTemplates.load(userFile: folder.url.appendingPathComponent("none.toml")).templates == CaptureTemplates.defaults)
    }

    @Test func capturesIntoClosedMissingAndOpenFiles() throws {
        let notes = try Folder()
        let todo = try notes.write("todo.org", "* Inbox\n** TODO Old\n* Later\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        let template = CaptureTemplates.defaults[0]
        let placed = try session.capture("* TODO New\n", template: template, root: notes.url.path).get()
        #expect(try String(contentsOf: todo, encoding: .utf8) == "* Inbox\n** TODO Old\n** TODO New\n* Later\n")
        #expect(placed.path == todo.path && placed.offset == ("* Inbox\n** TODO Old\n" as NSString).length)

        _ = try session.capture("* Note\n", template: CaptureTemplates.defaults[1], root: notes.url.path).get()
        #expect(try String(contentsOf: notes.url.appendingPathComponent("notes.org"), encoding: .utf8) == "* Inbox\n** Note\n")

        session.open(todo.path)
        _ = try session.capture("* TODO Third\n", template: template, root: notes.url.path).get()
        #expect(session.document?.text == "* Inbox\n** TODO Old\n** TODO New\n** TODO Third\n* Later\n")

        // An ID's file is resolved by the caller.
        let id = CaptureTemplate(key: "i", name: "", target: .id("x1"), template: "")
        let ided = try notes.write("ided.org", "* Target\n:PROPERTIES:\n:ID: x1\n:END:\n")
        _ = try session.capture("* Child\n", template: id, root: nil, file: ided.path).get()
        #expect(try String(contentsOf: ided, encoding: .utf8) == "* Target\n:PROPERTIES:\n:ID: x1\n:END:\n** Child\n")
    }
}

@MainActor
struct ClockModelTests {
    @Test func clocksInAndOutAcrossFiles() throws {
        let notes = try Folder()
        let work = try notes.write("work.org", "* Task\nBody\n")
        let other = try notes.write("other.org", "* Other\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(work.path)
        session.reveal(2)
        let stateFile = notes.url.appendingPathComponent("clock.json")
        let clock = ClockModel(file: stateFile)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        _ = clock.clockIn(session, now: start)
        #expect(clock.running?.heading == "Task")
        #expect(ClockModel(file: stateFile).running == clock.running)

        // Out from another file: the clocked file's buffer is still open behind it and takes
        // the change.
        session.open(other.path)
        let message = clock.clockOut(session, now: start.addingTimeInterval(95 * 60))
        #expect(message == "Clock stopped after 1:35")
        #expect(clock.running == nil)
        #expect(session.dirtyPaths == [work.path])
        #expect(session.saveAll())
        let text = try String(contentsOf: work, encoding: .utf8)
        #expect(text.hasPrefix("* Task\n:LOGBOOK:\nCLOCK: [") && text.contains("=>  1:35\n:END:\nBody\n"), "\(text)")
    }
}

@MainActor
struct BufferTests {
    @Test func buffersKeepEditsWhileOthersShow() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n")
        let b = try notes.write("b.org", "* B\n")
        let c = try notes.write("c.org", "* C\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.saveMode = .explicit
        session.open(a.path)
        _ = session.perform(SetTodo(keyword: "TODO"), path: a.path, at: 0, expect: nil)
        session.open(b.path)
        #expect(session.path == b.path)
        #expect(session.openPaths == [a.path, b.path])
        #expect(session.dirtyPaths == [a.path])
        // A background buffer takes commands for its file, not the disk.
        _ = session.perform(SetTodo(keyword: "DONE"), path: a.path, at: 0, expect: nil)
        #expect(try String(contentsOf: a, encoding: .utf8) == "* A\n")
        #expect(session.openDocuments.first { $0.path == a.path }?.document.text.hasPrefix("* DONE A") == true)

        session.open(a.path)
        #expect(session.document?.text.hasPrefix("* DONE A") == true)
        session.open(c.path)
        // Opened after the current buffer.
        #expect(session.openPaths == [a.path, c.path, b.path])
        session.cycle(1)
        #expect(session.path == b.path)
        session.cycle(1)
        #expect(session.path == a.path)
        session.showPrevious()
        #expect(session.path == b.path)
        #expect(session.recentPaths == [b.path, a.path, c.path])

        session.kill(b.path)
        #expect(session.path == a.path)
        #expect(session.openPaths == [a.path, c.path])
        #expect(session.saveAll())
        #expect(try String(contentsOf: a, encoding: .utf8).hasPrefix("* DONE A"))
        session.kill(a.path)
        session.kill(c.path)
        #expect(session.path == nil && session.document == nil && session.openPaths.isEmpty)
    }

    @Test func backgroundBuffersFollowTheDisk() throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* A\n")
        let b = try notes.write("b.org", "* B\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(a.path)
        session.open(b.path)
        try notes.write("a.org", "* A changed\n")
        session.fileChanged(a.path)
        #expect(session.openDocuments.first { $0.path == a.path }?.document.text == "* A changed\n")
    }
}

@MainActor
struct LinkFollowTests {
    @Test func followsLinksOfEachKind() async throws {
        let notes = try Folder()
        let a = try notes.write("a.org", "* Start\nSee <<here>>.\n* Second [1/2]\n:PROPERTIES:\n:CUSTOM_ID: two\n:END:\n")
        let b = try notes.write("sub/b.org", "* Target heading\n:PROPERTIES:\n:ID: 1234-ABCD\n:END:\nline 5\nline 6\n")
        _ = try notes.write("pic.png", "not really")
        let workspace = try WorkspaceModel(directory: nil)
        try await workspace.addRoot(notes.url)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(a.path)
        let text = { (path: String) in try? String(contentsOfFile: path, encoding: .utf8) }
        func follow(_ raw: String) -> LinkFollow { session.follow(Links.parse(bracket: raw), workspace: workspace, isText: { $0.hasSuffix(".org") }) }

        #expect(follow("here") == .shown)
        #expect(session.revealRequest?.offset == (text(a.path)! as NSString).range(of: "<<here>>").location)
        #expect(follow("#two") == .shown)
        #expect(follow("Second") == .shown)
        #expect(follow("Nowhere") == .message("No match for fuzzy expression: Nowhere"))

        #expect(follow("file:sub/b.org::5") == .shown)
        #expect(session.path == b.path)
        #expect(session.revealRequest?.offset == (text(b.path)! as NSString).range(of: "line 5").location)
        session.open(a.path)
        #expect(follow("file:sub/b.org::*Target heading") == .shown && session.path == b.path)
        session.open(a.path)
        #expect(follow("id:1234-ABCD") == .shown && session.path == b.path)
        #expect(follow("id:none") == .message("No heading has the ID none"))
        // Relative to the open file (now sub/b.org); files Orgstar doesn't edit go to macOS.
        #expect(follow("file:../pic.png") == .openExternally(URL(fileURLWithPath: (notes.url.appendingPathComponent("pic.png").path as NSString).standardizingPath)))
        #expect(follow("file:pic.png") == .message("No file " + (notes.url.appendingPathComponent("sub/pic.png").path as NSString).standardizingPath))
        #expect(follow("https://orgmode.org/a b") == .openExternally(URL(string: "https://orgmode.org/a%20b")!))
        #expect(follow("doi:10.1000/182") == .openExternally(URL(string: "https://doi.org/10.1000/182")!))
        #expect(follow("shell:rm -rf x") == .message("orgstar doesn't run shell links"))
    }

    @Test func followsAttachmentAndRadioLinks() throws {
        let notes = try Folder()
        let text = "* Task\n:PROPERTIES:\n:ID: ab12-cd\n:END:\nSee [[attachment:scan.pdf]] and <<<the plan>>>.\n* Later\nAs in The Plan.\n"
        let a = try notes.write("a.org", text)
        let scan = try notes.write("data/ab/12-cd/scan.pdf", "pdf")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(a.path)
        let tree = try #require(session.document?.tree)
        func follow(_ needle: String) throws -> LinkFollow {
            let link = try #require(Links.link(at: (text as NSString).range(of: needle).location + 1, text: text, tree: tree)?.link)
            return session.follow(link, workspace: nil, isText: { $0.hasSuffix(".org") })
        }
        #expect(try follow("attachment:") == .openExternally(URL(fileURLWithPath: (scan.path as NSString).standardizingPath)))
        #expect(try follow("The Plan") == .shown)
        #expect(session.revealRequest?.offset == (text as NSString).range(of: "<<<the plan>>>").location)
    }
}
