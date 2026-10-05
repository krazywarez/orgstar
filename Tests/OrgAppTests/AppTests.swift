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
    @Test func topLevelFilesAndTheOpenBuffer() async throws {
        let notes = try Folder()
        try notes.write("a.org", "* TODO Pay rent\nSCHEDULED: <2026-10-05 Mon>\n")
        try notes.write("sub/b.org", "* Hidden <2026-10-05 Mon>\n")
        try notes.write("old.org_archive", "* Archived <2026-10-05 Mon>\n")
        let model = try WorkspaceModel(directory: nil)
        try await model.addRoot(notes.url)
        let agenda = AgendaModel(workspace: model)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)))

        await agenda.refresh(open: nil, now: now, calendar: utc)
        #expect(agenda.days.count == 10)
        #expect(agenda.days[3].isToday)
        #expect(agenda.days[3].items.map(\.text) == ["TODO Pay rent"])

        agenda.includeSubfolders = true
        await agenda.refresh(open: nil, now: now, calendar: utc)
        #expect(agenda.days[3].items.map(\.text) == ["TODO Pay rent", "Hidden "])

        let path = try #require(agenda.files.first { $0.hasSuffix("/a.org") })
        await agenda.refresh(open: (path, "* DONE Pay rent\nSCHEDULED: <2026-10-05 Mon>\n"), now: now, calendar: utc)
        #expect(agenda.days[3].items.first?.text == "DONE Pay rent")

        agenda.shift(forward: true, now: now, calendar: utc)
        await agenda.refresh(open: nil, now: now, calendar: utc)
        #expect(agenda.days.first?.day == Days.absolute(year: 2026, month: 10, day: 12))
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
        await agenda.refresh(open: nil)
        #expect(agenda.list.map(\.text) == ["TODO One", "TODO Three"])
        agenda.mode = .match("work", todoOnly: false)
        await agenda.refresh(open: nil)
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
