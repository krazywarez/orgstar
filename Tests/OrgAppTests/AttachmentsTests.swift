import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// org-attach's commands against Emacs: the text after each step, the link stored and the
/// files left, run in the same folder.
struct AttachmentsTests {
    static let id = "6a1b2c3d-0000-4000-8000-000000000001"
    static let notes = """
        * Task
        Body.
        * Done :work:
        :PROPERTIES:
        :ID:       20240101T120000
        :END:
        * Moved

        """

    static func setUp(_ folder: URL) throws {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data/202401/01T120000"), withIntermediateDirectories: true)
        try notes.write(to: folder.appendingPathComponent("notes.org"), atomically: true, encoding: .utf8)
        for name in ["a", "b", "c", "d", "e", "f"] {
            try "\(name)\n".write(to: folder.appendingPathComponent("src/\(name).txt"), atomically: true, encoding: .utf8)
        }
    }

    /// Every file and folder under `folder`, relative, sorted.
    static func listing(_ folder: URL) -> [String] {
        let base = folder.path + "/"
        let paths = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        return paths.filter { !$0.hasPrefix(base) }.sorted()
    }

    @Test func commandsMatchEmacs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-attach-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.setUp(folder)
        let dir = folder.path
        let form = #"""
            (progn
              (require 'org) (require 'org-attach) (require 'json)
              (let ((out nil))
                (cl-letf (((symbol-function 'org-id-new) (lambda (&rest _) "\#(Self.id)"))
                          ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil))
                          ((symbol-function 'read-directory-name) (lambda (&rest _) "\#(dir)/elsewhere/")))
                  (with-current-buffer (find-file-noselect "\#(dir)/notes.org")
                    (cl-flet ((at (h) (goto-char (point-min)) (re-search-forward (concat "^\\* " h)) (beginning-of-line))
                              (rec () (push (buffer-substring-no-properties (point-min) (point-max)) out)))
                      (at "Task") (org-attach-attach "\#(dir)/src/a.txt") (rec) (push (caar org-stored-links) out)
                      (at "Task") (org-attach-attach "\#(dir)/src/b.txt" nil 'mv) (rec)
                      (at "Task") (org-attach-attach "\#(dir)/src/e.txt" nil 'ln)
                      (at "Task") (org-attach-attach "\#(dir)/src/f.txt" nil 'lns) (rec)
                      (at "Task") (org-attach-delete-one "a.txt") (rec)
                      (at "Task") (org-attach-sync) (rec)
                      (at "Task") (push (string-join (directory-files (org-attach-dir) nil "^[^.]") " ") out)
                      (at "Task") (org-attach-delete-all t) (rec)
                      (at "Task") (org-attach-sync) (rec)
                      (at "Done") (org-attach-attach "\#(dir)/src/c.txt") (rec)
                      (at "Moved") (org-attach-set-directory) (org-attach-attach "\#(dir)/src/d.txt") (rec)
                      (at "Moved") (org-attach-unset-directory) (rec))))
                (with-temp-file "\#(dir)/out.json" (insert (json-encode (vconcat (nreverse out)))))))
            """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "--eval", form]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let emacs = try JSONDecoder().decode([String].self, from: Data(contentsOf: folder.appendingPathComponent("out.json")))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("out.json"))
        let emacsFiles = Self.listing(folder)

        try Self.setUp(folder)
        let path = folder.appendingPathComponent("notes.org").path
        var entry = Attachments.Entry(text: Self.notes, offset: 0, path: path, idDir: "data/")
        var ours: [String] = []
        func at(_ heading: String) {
            entry = Attachments.Entry(text: entry.text, offset: (entry.text as NSString).range(of: "* " + heading).location, path: path, idDir: "data/")
        }
        func rec() { ours.append(entry.text) }
        func src(_ name: String) -> URL { folder.appendingPathComponent("src/\(name).txt") }
        at("Task"); _ = try Attachments.directoryCreating(&entry, newID: { Self.id })
        let link = try Attachments.attach(src("a"), method: .cp, to: &entry); rec(); ours.append(link.link)
        at("Task"); try Attachments.attach(src("b"), method: .mv, to: &entry); rec()
        at("Task"); try Attachments.attach(src("e"), method: .ln, to: &entry)
        at("Task"); try Attachments.attach(src("f"), method: .lns, to: &entry); rec()
        at("Task"); try Attachments.delete("a.txt", in: entry); rec()
        at("Task"); _ = Attachments.sync(&entry); rec()
        at("Task"); ours.append(Attachments.files(in: Attachments.directory(entry)!).joined(separator: " "))
        at("Task"); try Attachments.deleteAll(&entry); rec()
        at("Task"); _ = Attachments.sync(&entry); rec()
        at("Done"); try Attachments.attach(src("c"), method: .cp, to: &entry); rec()
        at("Moved"); _ = Attachments.setDirectory(dir + "/elsewhere/", in: &entry); try Attachments.attach(src("d"), method: .cp, to: &entry); rec()
        at("Moved"); _ = Attachments.unsetDirectory(&entry); rec()
        try entry.text.write(toFile: path, atomically: true, encoding: .utf8)

        #expect(ours.count == emacs.count, "\(log)")
        for (index, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs, "step \(index)")
        }
        // Emacs leaves the buffer unsaved.
        #expect(Self.listing(folder).filter { $0 != "notes.org" } == emacsFiles.filter { $0 != "notes.org" })
    }

    /// `org-attach-dir` without the file system check, for each inheritance setting.
    @Test func inheritanceMatchesEmacs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-attach-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = """
            #+PROPERTY: DIR top/
            * Parent
            :PROPERTIES:
            :ID:       aabbcc
            :END:
            ** Child
            ** Child with DIR
            :PROPERTIES:
            :DIR:      ~/own/
            :END:
            *** Grandchild
            * Plain

            """
        let path = folder.appendingPathComponent("notes.org").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let headings = ["Parent", "Child", "Child with DIR", "Grandchild", "Plain"]
        let settings = ["selective": nil, "t": true, "nil": false] as [String: Bool?]
        let tree = OrgParser.parse(text)
        for (symbol, inherit) in settings {
            let form = #"""
                (progn (require 'org) (require 'org-attach)
                  (setq org-attach-use-inheritance '\#(symbol) org-use-property-inheritance '("DIR"))
                  (with-current-buffer (find-file-noselect "\#(path)")
                    (dolist (h '(\#(headings.map { "\"\($0)\"" }.joined(separator: " "))))
                      (goto-char (point-min)) (re-search-forward (concat "^\\*+ " h "$"))
                      (princ (format "%s\n" (let ((d (org-attach-dir nil t))) (if d (directory-file-name (expand-file-name d)) "none")))))))
                """#
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "--eval", form]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let emacs = output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") || $0 == "none" }
            var withDIR = tree.settings
            withDIR.propertyInheritance = .only(["DIR"])
            let ours = headings.map { heading in
                OrgAttach.directory(tree: OrgParser.parse(text, defaults: withDIR), at: (text as NSString).range(of: "* " + heading + "\n").location,
                                    path: path, inherit: inherit, noFSCheck: true) { _ in false } ?? "none"
            }
            #expect(ours == emacs, "\(symbol): \(output)")
        }
    }

    @Test func expandKeepsPrivate() {
        #expect(OrgAttach.expand("other/", in: "/private/tmp/n") == "/private/tmp/n/other")
        #expect(OrgAttach.expand("../x", in: "/private/tmp/n") == "/private/tmp/x")
    }

    @Test func urlNames() {
        #expect(Attachments.name(ofURL: "https://example.com/a/b.png") == "b.png")
        #expect(Attachments.name(ofURL: "https://example.com/a/b.png?x=1") == "b.png?x=1")
        #expect(Attachments.name(ofURL: "https://example.com/") == "")
    }

    @Test func folderForID() {
        let none: (String) -> Bool = { _ in false }
        #expect(OrgAttach.folder(forID: "abcdef12", idDir: "data/", in: "/n", existing: false, isDirectory: none) == "/n/data/ab/cdef12")
        #expect(OrgAttach.folder(forID: "ab", idDir: "data/", in: "/n", existing: false, isDirectory: none) == "/n/data/__/a/ab")
        #expect(OrgAttach.folder(forID: "abcdef12", idDir: "~/.attach/", in: "/n", existing: true, isDirectory: { $0 == "/n/data" || $0 == "/n/data/abcdef/12" })
                == "/n/data/abcdef/12")
    }
}

@MainActor
struct AttachmentInboxTests {
    @Test func sharedFilesAttachToAnEntryOfAClosedFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-inbox-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shared = folder.appendingPathComponent("photo.jpg")
        try Data("jpeg".utf8).write(to: shared)
        let inbox = AttachmentInbox(folder: folder.appendingPathComponent("inbox"))
        try inbox.add([shared])
        let batch = try #require(inbox.batches().first)
        #expect(AttachmentInbox.files(in: batch).map(\.lastPathComponent) == ["photo.jpg"])

        let notes = folder.appendingPathComponent("notes.org").path
        try "* Trip\n:PROPERTIES:\n:ID:       abcdef\n:END:\n".write(toFile: notes, atomically: true, encoding: .utf8)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.appendingPathComponent(".r")))
        let message = session.attach(AttachmentInbox.files(in: batch), to: notes, at: 0)
        inbox.remove(batch)
        #expect(message == "File \"photo.jpg\" is now an attachment")
        #expect(try String(contentsOfFile: notes, encoding: .utf8).hasPrefix("* Trip" + String(repeating: " ", count: 63) + ":ATTACH:\n"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("data/ab/cdef/photo.jpg").path))
        #expect(inbox.batches().isEmpty)
    }
}
