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
