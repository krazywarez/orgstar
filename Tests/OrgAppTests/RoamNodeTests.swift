import Foundation
import Testing
@testable import OrgApp

struct RoamNodeTests {
    /// `org-roam-node-slugify` from org-roam 2.3, run in Emacs. Titles and slugs go through
    /// UTF-8 files: Emacs decodes its command line by the locale.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func slugsMatchOrgRoam() throws {
        let titles = ["Hello World", "Café au lait", "  Spaces  and__underscores ", "C++ & Rust!", "Привет мир", "日本語のノート", "naïve résumé", "x", "---", "Ångström 2026"]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-slug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("titles.txt"), output = folder.appendingPathComponent("slugs.txt")
        try titles.joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        let form = """
            (progn (require 'ucs-normalize) (require 'seq) (require 'subr-x)
              (let* ((coding-system-for-read 'utf-8) (coding-system-for-write 'utf-8)
                     (slug-trim-chars '(#x300 #x301 #x302 #x303 #x304 #x306 #x307 #x308 #x309 #x30A #x30B #x30C #x31B #x323 #x324 #x325 #x327 #x32D #x32E #x330 #x331))
                     (titles (split-string (with-temp-buffer (insert-file-contents "\(input.path)") (buffer-string)) "\n")))
                (with-temp-file "\(output.path)"
                  (dolist (title titles)
                    (insert (thread-last title (ucs-normalize-NFD-string) (seq-remove (lambda (char) (memq char slug-trim-chars)))
                      (apply #'string) (ucs-normalize-NFC-string) (replace-regexp-in-string "[^[:alnum:]]" "_")
                      (replace-regexp-in-string "__*" "_") (replace-regexp-in-string "^_" "") (replace-regexp-in-string "_$" "") (downcase))
                            "\n")))))
            """
        _ = try DailiesTests.emacs(form)
        let emacs = try String(contentsOf: output, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(Array(emacs.prefix(titles.count)) == titles.map(RoamNode.slug))
    }

    @Test func newNodeFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-roam-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 9, minute: 5, second: 7))!
        let node = try RoamNode.create(title: "Field Notes", in: folder, now: now, id: { "abc-123" })
        #expect((node.path as NSString).lastPathComponent == "20261013090507-field_notes.org")
        #expect(node.id == "abc-123")
        let text = try String(contentsOfFile: node.path, encoding: .utf8)
        #expect(text == ":PROPERTIES:\n:ID:       abc-123\n:END:\n#+title: Field Notes\n")
        // The same second and title again: the file is there, so nothing is overwritten.
        #expect(throws: (any Error).self) { try RoamNode.create(title: "Field Notes", in: folder, now: now, id: { "other" }) }
    }
}
