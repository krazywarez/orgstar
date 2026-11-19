import Foundation
import Testing
@testable import OrgApp
import OrgCore

/// Denote and denote-journal themselves, run in Emacs, when they're installed: the load-path
/// directories in `ORGSTAR_DENOTE` (colon-separated), else a Doom or package.el install.
struct DenoteOracleTests {
    static let loadPath: [String]? = {
        if let paths = ProcessInfo.processInfo.environment["ORGSTAR_DENOTE"] { return paths.split(separator: ":").map(String.init) }
        let fm = FileManager.default, home = NSHomeDirectory()
        let roots = ["\(home)/.config/emacs/.local/straight", "\(home)/.emacs.d/.local/straight"].flatMap { root in
            ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix("build-") }.sorted().reversed().map { "\(root)/\($0)" }
        } + ["\(home)/.emacs.d/elpa", "\(home)/.config/emacs/elpa"]
        for root in roots {
            let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            let dirs = ["denote", "denote-journal"].compactMap { package in
                names.filter { $0 == package || ($0.hasPrefix(package + "-") && $0.dropFirst(package.count + 1).first?.isNumber == true) }
                    .sorted().last.map { "\(root)/\($0)" }
            }
            if dirs.count == 2 { return dirs }
        }
        return nil
    }()

    static var enabled: Bool { loadPath != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil }

    /// Runs `body` with Denote loaded, `denote-directory` at `folder` and nothing backed up.
    static func denote(_ folder: URL, _ body: String) throws {
        let paths = loadPath!.map(\.debugDescription).joined(separator: " ")
        _ = try DailiesTests.emacs("""
            (progn (setq load-path (append (list \(paths)) load-path) make-backup-files nil auto-save-default nil create-lockfiles nil
                         coding-system-for-read 'utf-8 coding-system-for-write 'utf-8)
              (require 'denote) (require 'denote-journal)
              (setq denote-directory \((folder.path + "/").debugDescription) denote-rename-confirmations nil)
              \(body))
            """)
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-denote-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test(.enabled(if: enabled)) func slugsMatchDenote() throws {
        let titles = ["Hello, World: a_test -- Note!", "  Café au lait  ", "C++ & Rust!", "Привет мир", "x=y/z", "a  -  b", "It's [done]", "日本語のノート", "a <b> c\\d"]
        let words = ["Emacs", "org-mode", "two words", "a_b", "Café", "x=1"]
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("in.txt"), output = dir.appendingPathComponent("out.txt")
        try (titles + words).joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)
        try Self.denote(dir, """
            (let ((lines (split-string (with-temp-buffer (insert-file-contents \(input.path.debugDescription)) (buffer-string)) "\\n")))
              (with-temp-file \(output.path.debugDescription)
                (dotimes (i (length lines))
                  (insert (denote-sluggify (if (< i \(titles.count)) 'title 'keyword) (nth i lines)) "\\n"))))
            """)
        let theirs = try Self.lines(output)
        #expect(Array(theirs.prefix(titles.count)) == titles.map(Denote.slug))
        #expect(Array(theirs.dropFirst(titles.count).prefix(words.count)) == words.map(Denote.keyword))
    }

    /// A note, a journal entry and a rename, as files Denote and orgstar each make.
    @Test(.enabled(if: enabled)) func filesMatchDenote() throws {
        let theirs = try Self.folder(), ours = try Self.folder()
        defer { try? FileManager.default.removeItem(at: theirs); try? FileManager.default.removeItem(at: ours) }
        let front = "#+title:      New Title\n#+signature:  Two Words\n#+filetags:   :Zeta:alpha:\n#+identifier: 20261011T080000\n\nBody\n"
        let old = "20261011T080000==1a--old__x.org"
        for dir in [theirs, ours] { try front.write(to: dir.appendingPathComponent(old), atomically: true, encoding: .utf8) }
        try Self.denote(theirs, """
            (progn
              (denote "Field Notes" (denote-keywords-sort (list "work" "ideas")) 'org nil "2026-10-11 12:00:05")
              (save-buffer)
              (let ((denote-journal-directory nil)) (denote-journal-new-entry "2026-10-11 12:00:00") (save-buffer))
              (denote-rename-file-using-front-matter \(theirs.appendingPathComponent(old).path.debugDescription)))
            """)
        _ = try DenoteNote.create(title: "Field Notes", keywords: ["work", "ideas"], in: ours.path, now: DailiesTests.day.addingTimeInterval(5))
        _ = try Dailies(directory: ours.path, journal: Dailies.Journal()).ensure(DailiesTests.day)
        let renamed = Denote.renamed(ours.appendingPathComponent(old).path, text: front)!
        try FileManager.default.moveItem(atPath: ours.appendingPathComponent(old).path, toPath: renamed)

        let names = try FileManager.default.contentsOfDirectory(atPath: theirs.path).sorted()
        #expect(names.count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ours.path).sorted() == names)
        for name in names {
            #expect(try String(contentsOf: ours.appendingPathComponent(name), encoding: .utf8)
                == String(contentsOf: theirs.appendingPathComponent(name), encoding: .utf8), "\(name)")
        }
    }
}
