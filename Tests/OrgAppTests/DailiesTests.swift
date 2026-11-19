import Foundation
import OrgCore
import OrgDocument
import OrgIndex
import Testing
@testable import OrgApp

struct DailiesTests {
    /// Sun 2026-10-11 12:00 local time.
    static var day: Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))! }

    static func emacs(_ form: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "--eval", form]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A new daily note's text: the head under the ID drawer `org-entry-put` makes, and the
    /// file name, as org-roam-capture fills them.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func newNotesMatchEmacs() throws {
        let seconds = Int(Self.day.timeIntervalSince1970)
        let heads = ["#+title: %<%Y-%m-%d>\n", "#+title: %<%A, %d %B %Y>", "#+title: Day %<%j>\n#+filetags: :daily:\n"]
        for head in heads {
            let theirs = try Self.emacs("""
                (progn (require 'org)
                  (let ((head (replace-regexp-in-string "%<\\\\([^>]*\\\\)>" (lambda (m) (format-time-string (match-string 1 m) (seconds-to-time \(seconds)))) \(head.debugDescription) t t)))
                    (with-temp-buffer (org-mode) (insert head) (unless (bolp) (insert "\\n"))
                      (org-entry-put (point-min) "ID" "abc") (princ (buffer-string)))))
                """)
            #expect(Dailies(directory: "/n", head: head).newText(Self.day, id: "abc") == theirs, "\(head)")
        }
        let name = try Self.emacs("(princ (format-time-string \"%Y-%m-%d.org\" (seconds-to-time \(seconds))))")
        #expect((Dailies(directory: "/n/daily").path(for: Self.day) as NSString).lastPathComponent == name)
    }

    @Test func nextAndPreviousNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-daily-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dailies = Dailies(directory: folder.path)
        for offset in [-3, -1, 0] { try dailies.ensure(Calendar.current.date(byAdding: .day, value: offset, to: Self.day)!) }
        try "x".write(to: folder.appendingPathComponent(".hidden.org"), atomically: true, encoding: .utf8)
        let today = dailies.path(for: Self.day)
        #expect(dailies.files().map { ($0 as NSString).lastPathComponent } == ["2026-10-08.org", "2026-10-10.org", "2026-10-11.org"])
        #expect(try (dailies.neighbor(of: today, by: -1) as NSString).lastPathComponent == "2026-10-10.org")
        #expect(throws: Dailies.Failure("Already at newest note")) { try dailies.neighbor(of: today, by: 1) }
        #expect(throws: Dailies.Failure("Not in a daily-note")) { try dailies.neighbor(of: "/elsewhere/x.org", by: 1) }
        // A new note isn't written over.
        #expect(try dailies.ensure(Self.day).created == false)
    }

    @Test func denoteJournalEntries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-journal-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = Dailies(directory: folder.path, journal: Dailies.Journal())
        let made = try journal.ensure(Self.day)
        #expect(made.created && (made.path as NSString).lastPathComponent == "20261011T120000--sunday-11-october-2026-1200__journal.org")
        #expect(try String(contentsOfFile: made.path, encoding: .utf8).hasPrefix("#+title:      Sunday 11 October 2026 12:00\n#+date:       [2026-10-11 Sun 12:00]\n#+filetags:   :journal:\n"))
        // Another time the same day finds the entry.
        let later = Calendar.current.date(byAdding: .hour, value: 3, to: Self.day)!
        #expect(try journal.ensure(later) == (made.path, false))
        try journal.ensure(Calendar.current.date(byAdding: .day, value: -2, to: Self.day)!)
        try "x".write(to: folder.appendingPathComponent("20261010T080000--not-a-journal__work.org"), atomically: true, encoding: .utf8)
        #expect(journal.files().map { ($0 as NSString).lastPathComponent } == ["20261009T120000--friday-9-october-2026-1200__journal.org", (made.path as NSString).lastPathComponent])
        #expect(try (journal.neighbor(of: made.path, by: -1) as NSString).lastPathComponent == "20261009T120000--friday-9-october-2026-1200__journal.org")
    }

    /// `denote-journal-interval`: one entry a week (Monday to Sunday), month or year.
    @Test func denoteJournalIntervals() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-journal-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = folder.appendingPathComponent("20261005T080000--monday__journal.org").path
        try "x".write(toFile: entry, atomically: true, encoding: .utf8)
        func found(_ interval: String, _ days: Int) -> Bool {
            Dailies(directory: folder.path, journal: Dailies.Journal(interval: interval)).path(for: Calendar.current.date(byAdding: .day, value: days, to: Self.day)!) == entry
        }
        // Self.day is Sunday 11 October 2026.
        #expect(found("weekly", 0) && found("weekly", -6) && !found("weekly", 1) && !found("weekly", -7))
        #expect(!found("daily", 0) && found("daily", -6))
        #expect(found("monthly", 20) && !found("monthly", 21))
        #expect(found("yearly", 81) && !found("yearly", 82))
    }

    @Test func newDenoteNote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-denote-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let note = try DenoteNote.create(title: "Field Notes", keywords: ["Work", "ideas"], in: folder, now: Self.day)
        #expect((note.path as NSString).lastPathComponent == "20261011T120000--field-notes__ideas_work.org" && note.id == "20261011T120000")
        #expect(try String(contentsOfFile: note.path, encoding: .utf8).hasPrefix("#+title:      Field Notes\n"))
        // The same second again under the folder: the next unused one, the date unchanged.
        let again = try DenoteNote.create(title: "Field Notes", keywords: ["work", "ideas"], in: folder, now: Self.day)
        #expect((again.path as NSString).lastPathComponent == "20261011T120001--field-notes__ideas_work.org")
        let sub = (folder as NSString).appendingPathComponent("projects")
        let other = try DenoteNote.create(title: "Plan", keywords: [], in: sub, roots: [folder], now: Self.day, signature: "Two Words", template: "* Goals\n")
        #expect((other.path as NSString).lastPathComponent == "20261011T120002==two=words--plan.org")
        #expect(try String(contentsOfFile: other.path, encoding: .utf8)
            == "#+title:      Plan\n#+date:       [2026-10-11 Sun 12:00]\n#+filetags:   \n#+identifier: 20261011T120002\n#+signature:  two=words\n\n* Goals\n")
        #expect(DenoteNote.subdirectories(of: folder) == ["projects"])
    }

    /// A RoamActions on `folder` that answers each prompt from `answers` by key, recording
    /// what it asked, what it opened and showed, and links inserted.
    @MainActor
    final class Harness {
        let folder: URL
        let session: DocumentSession
        var answers: [String: String] = [:]
        var asked: [Prompt] = []
        var opened: [String] = []
        var shown: [String] = []
        var links: [(String, String)] = []
        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-denote-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent(".r")))
        }
        deinit { try? FileManager.default.removeItem(at: folder) }
        var actions: RoamActions {
            RoamActions(session: session, roots: { [self.folder.path] }, nodes: { [] }, show: { self.shown.append($0) },
                        ask: { prompt, reply in self.asked.append(prompt); reply(self.answers[prompt.key]) },
                        open: { path, _ in self.opened.append(path); self.session.open(path) }, insertLink: { self.links.append(($0, $1)) }, refresh: {})
        }
        @discardableResult
        func write(_ name: String, _ text: String) throws -> String {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        func names() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }
    }

    /// `denote-rename-file`: the questions start with the current values; the file and its
    /// front matter change.
    @MainActor
    @Test func renamesByPrompting() throws {
        let h = try Harness()
        let path = try h.write("20261011T120000--old__x.org", "#+title:      Old\n#+date:       [2026-10-11 Sun 12:00]\n#+filetags:   :x:\n#+identifier: 20261011T120000\n\nBody\n")
        h.session.open(path)
        h.answers = ["title": "New Name", "keywords": "b, a"]
        h.actions.run("app.node.rename")
        #expect(h.asked.map(\.initial) == ["Old", "x"])
        let new = h.folder.appendingPathComponent("20261011T120000--new-name__a_b.org").path
        #expect(h.opened == [new], "\(h.shown)")
        #expect(try String(contentsOfFile: new, encoding: .utf8) == "#+title:      New Name\n#+date:       [2026-10-11 Sun 12:00]\n#+filetags:   :a:b:\n#+identifier: 20261011T120000\n\nBody\n")
    }

    @MainActor
    @Test func renamesFolderFromFrontMatter() throws {
        let h = try Harness()
        try h.write("20261011T120000--old__x.org", "#+title:      One\n#+filetags:   :y:\n")
        try h.write("20261011T130000--two.org", "#+title:      Two\n")
        try h.write("plain.org", "#+title: Plain\n")
        h.answers = ["folder": "."]
        h.actions.run("app.node.rename-folder-from-front-matter")
        #expect(h.names() == ["20261011T120000--one__y.org", "20261011T130000--two.org", "plain.org"])
        #expect(h.shown == ["Renamed 1 note"])
    }

    @MainActor
    @Test func silos() throws {
        let h = try Harness()
        let silo = h.folder.appendingPathComponent("silo").path
        try FileManager.default.createDirectory(atPath: silo, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        defaults.set(h.folder.path + ":" + silo, forKey: "denoteSiloDirectories")
        defer { defaults.removeObject(forKey: "denoteSiloDirectories") }
        h.answers = ["silo": DenoteNote.abbreviated(silo), "title": "In Silo", "keywords": "k"]
        h.actions.run("app.node.silo-create")
        #expect(h.asked.first?.choices == [DenoteNote.abbreviated(h.folder.path), DenoteNote.abbreviated(silo)])
        #expect(h.opened.count == 1 && h.opened[0].hasPrefix(silo + "/") && h.opened[0].hasSuffix("--in-silo__k.org"))
    }

    @MainActor
    @Test func sequenceCommands() throws {
        let h = try Harness()
        let root = try h.write("20261001T090000==1--root.org", "#+title:      Root\n")
        let child = try h.write("20261002T090000==1=1--child__k.org", "#+title:      Child\n#+filetags:   :k:\n#+identifier: 20261002T090000\n#+signature:  1=1\n\nC\n")
        try h.write("20261003T090000==1=1=1--grandchild.org", "#+title:      Grandchild\n")
        let third = try h.write("20261004T090000==1=3--third.org", "#+title:      Third\n")
        try h.write("20261005T090000==2--two.org", "#+title:      Two\n")
        // A new child of the open note.
        h.session.open(root)
        h.answers = ["title": "Kid", "keywords": ""]
        h.actions.run("app.node.sequence-new-child-of-current")
        #expect(h.opened.last.map { ($0 as NSString).lastPathComponent }?.hasSuffix("==1=4--kid.org") == true, "\(h.shown)")
        // The next sibling skips the missing 1=2.
        h.session.open(child)
        h.actions.run("app.node.sequence-next-sibling")
        #expect(h.opened.last == third)
        // Find: the parent opens at once.
        h.session.open(child)
        h.answers = ["relation": "parent"]
        h.actions.run("app.node.sequence-find")
        #expect(h.opened.last == root)
        // Reparenting with descendants under 2.
        h.session.open(child)
        h.answers = ["sequence": "20261005T090000==2--two.org"]
        h.actions.run("app.node.sequence-reparent-recursive")
        #expect(h.names().contains("20261002T090000==2=1--child__k.org") && h.names().contains("20261003T090000==2=1=1--grandchild.org"), "\(h.names()) \(h.shown)")
        #expect(try String(contentsOfFile: h.folder.appendingPathComponent("20261002T090000==2=1--child__k.org").path, encoding: .utf8).contains("#+signature:  2=1\n"))
        // A link to a sequence note says its sequence and title.
        h.answers = ["sequence": "20261004T090000==1=3--third.org"]
        h.actions.run("app.node.sequence-link")
        #expect(h.links.last?.0 == "denote:20261004T090000" && h.links.last?.1 == "1=3  Third")
    }

    /// `denote-org-capture`: the note's questions first, then the entry filed in it.
    @MainActor
    @Test func denoteCapture() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-capture-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "orgstar-capture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("title signature keywords", forKey: "denotePrompts")
        let capture = DenoteCapture(roots: [folder.path], paths: ["/x/20260101T000000--a__old.org"], defaults: defaults)
        #expect(capture.questions.map(\.prompt) == ["New file TITLE", "New file SIGNATURE", "New file KEYWORDS"])
        #expect(capture.questions[2].choices == ["old"])
        let path = try capture.create(["Captured", "1a", "b a"], now: Self.day)
        #expect((path as NSString).lastPathComponent == "20261011T120000==1a--captured__a_b.org")
        let file = folder.appendingPathComponent("capture.toml")
        try "[[template]]\nkey = \"n\"\nname = \"Note\"\ndenote = true\ntemplate = \"* %?\"\n".write(to: file, atomically: true, encoding: .utf8)
        let loaded = CaptureTemplates.load(userFile: file)
        #expect(loaded.problems.isEmpty, "\(loaded.problems)")
        let template = try #require(loaded.templates.first)
        #expect(template.options.denote)
    }

    /// `denote-prompts` sets the questions after the title and their order.
    @MainActor
    @Test func denotePromptsInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-denote-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("work"), withIntermediateDirectories: true)
        var asked: [String] = []
        let answers = ["signature": "a1", "subdirectory": "work", "date": "2026-10-11 09:30", "template": "memo", "keywords": "beta, alpha"]
        var created: String?
        let actions = RoamActions(session: DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent(".r"))),
                                  roots: { [folder.path] }, nodes: { [] }, show: { _ in }, ask: { prompt, reply in asked.append(prompt.key); reply(answers[prompt.key]) },
                                  open: { _, _ in }, insertLink: { _, _ in }, refresh: {})
        actions.createDenote("Field Notes", roots: [folder.path], prompts: ["title", "signature", "subdirectory", "date", "file-type", "template", "keywords"],
                             templates: [("report", "* R\n"), ("memo", "* M\n")], keywords: []) { choice in
            if case .created(let path, _, _) = choice { created = path }
        }
        #expect(asked == ["signature", "subdirectory", "date", "template", "keywords"])
        let path = try #require(created)
        #expect(path == folder.appendingPathComponent("work/20261011T093000==a1--field-notes__alpha_beta.org").path)
        #expect(try String(contentsOfFile: path, encoding: .utf8).hasSuffix("#+signature:  a1\n\n* M\n"))
    }

    @MainActor
    @Test func renamesFromFrontMatter() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-denote-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("20261011T120000--old__x.org").path
        try "#+title:      Old\n#+filetags:   :x:\n".write(toFile: old, atomically: true, encoding: .utf8)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent(".r")))
        session.open(old)
        var opened: String?
        var shown: [String] = []
        let actions = RoamActions(session: session, roots: { [folder.path] }, nodes: { [] }, show: { shown.append($0) }, ask: { $1(nil) },
                                  open: { path, _ in opened = path }, insertLink: { _, _ in }, refresh: {})
        if case .failed = session.perform(ReplaceText(old: "#+title:      Old\n#+filetags:   :x:\n", new: "#+title:      New Name\n#+filetags:   :x:y:\n"), path: old, at: 0, expect: nil) {
            Issue.record("edit failed"); return
        }
        actions.renameFromFrontMatter()
        let new = folder.appendingPathComponent("20261011T120000--new-name__x_y.org").path
        #expect(opened == new && !FileManager.default.fileExists(atPath: old), "\(shown)")
        #expect(try String(contentsOfFile: new, encoding: .utf8) == "#+title:      New Name\n#+filetags:   :x:y:\n")
    }

    @MainActor
    @Test func captureFilesTheEntryAtTheEnd() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-daily-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent(".r")))
        var opened: (String, Int)?
        let actions = RoamActions(session: session, roots: { [folder.path] }, nodes: { [] }, show: { Issue.record("\($0)") }, ask: { $1(nil) },
                                  open: { opened = ($0, $1) }, insertLink: { _, _ in }, refresh: {})
        actions.capture(Self.day)
        let path = folder.appendingPathComponent("daily/2026-10-11.org").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.hasPrefix(":PROPERTIES:\n:ID:       "))
        #expect(text.hasSuffix(":END:\n#+title: 2026-10-11\n* \n"))
        #expect(opened?.0 == path && opened?.1 == (text as NSString).length - 1)
    }
}

struct NodeIndexTests {
    @Test func denoteNotesAreNodes() throws {
        let store = try IndexStore()
        let settings = IndexSettings()
        try store.write(FileRecord(path: "/n/20261011T120000--a__x.org", root: "/n", kind: .org, bytes: Array("#+title: A note\n".utf8), mtime: 1, settings: settings))
        try store.write(FileRecord(path: "/n/20261012T120000--untitled.org", root: "/n", kind: .org, bytes: [], mtime: 1, settings: settings))
        try store.write(FileRecord(path: "/n/plain.org", root: "/n", kind: .org, bytes: Array("#+title: Plain\n".utf8), mtime: 1, settings: settings))
        let nodes = try store.denoteNodes()
        #expect(nodes.map(\.id) == ["20261011T120000", "20261012T120000"])
        #expect(nodes.map(\.title) == ["A note", "20261012T120000--untitled"])
    }

    @Test func filesAndHeadingsWithIDsAreNodes() throws {
        let store = try IndexStore()
        let settings = IndexSettings()
        let text = ":PROPERTIES:\n:ID:       file-1\n:END:\n#+title: Daily\n* Task\n:PROPERTIES:\n:ID: h-1\n:END:\n* Plain\n"
        try store.write(FileRecord(path: "/n/2026-10-11.org", root: "/n", kind: .org, bytes: Array(text.utf8), mtime: 1, settings: settings))
        try store.write(FileRecord(path: "/n/untitled.org", root: "/n", kind: .org, bytes: Array(":PROPERTIES:\n:ID: f2\n:END:\n".utf8), mtime: 1, settings: settings))
        let nodes = try store.nodes()
        #expect(nodes.map(\.id) == ["file-1", "f2", "h-1"])
        #expect(nodes.map(\.title) == ["Daily", "untitled", "Task"])
        #expect(try store.headings(withID: "file-1").map(\.ordinal) == [HeadingLocation.fileOrdinal])
        #expect(try store.headings(withID: "h-1").map(\.title) == ["Task"])
    }
}
