import Foundation
import Testing
@testable import OrgApp
@testable import OrgCore

/// Denote and denote-journal themselves, run in Emacs, when they're installed: the load-path
/// directories in `ORGSTAR_DENOTE` (colon-separated), else a Doom or package.el install.
struct DenoteOracleTests {
    /// The load-path directories of denote and denote-journal, and of denote-org and
    /// denote-sequence when they're there too.
    static let loadPath: [String]? = {
        if let paths = ProcessInfo.processInfo.environment["ORGSTAR_DENOTE"] { return paths.split(separator: ":").map(String.init) }
        let fm = FileManager.default, home = NSHomeDirectory()
        let roots = ["\(home)/.config/emacs/.local/straight", "\(home)/.emacs.d/.local/straight"].flatMap { root in
            ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix("build-") }.sorted().reversed().map { "\(root)/\($0)" }
        } + ["\(home)/.emacs.d/elpa", "\(home)/.config/emacs/elpa"]
        for root in roots {
            let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            let dirs = ["denote", "denote-journal", "denote-org", "denote-sequence"].compactMap { package in
                names.filter { $0 == package || ($0.hasPrefix(package + "-") && $0.dropFirst(package.count + 1).first?.isNumber == true) }
                    .sorted().last.map { "\(root)/\($0)" }
            }
            if dirs.count >= 2, dirs[0].hasSuffix("/denote") || dirs[0].contains("/denote-") { return dirs }
        }
        return nil
    }()

    static func has(_ package: String) -> Bool { enabled && loadPath!.contains { ($0 as NSString).lastPathComponent == package || ($0 as NSString).lastPathComponent.hasPrefix(package + "-") && ($0 as NSString).lastPathComponent.dropFirst(package.count + 1).first?.isNumber == true } }

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

    /// A note in a subfolder with a signature and a template, dated a second some file's
    /// identifier already has.
    @Test(.enabled(if: enabled)) func optionsMatchDenote() throws {
        let theirs = try Self.folder(), ours = try Self.folder()
        defer { try? FileManager.default.removeItem(at: theirs); try? FileManager.default.removeItem(at: ours) }
        let taken = "20261011T093000--taken.org"
        for dir in [theirs, ours] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("work"), withIntermediateDirectories: true)
            try "x\n".write(to: dir.appendingPathComponent(taken), atomically: true, encoding: .utf8)
        }
        let template = "* Goals\n\n* Notes\n"
        try Self.denote(theirs, """
            (let ((denote-templates '((plan . \(template.debugDescription)))))
              (denote "Q4 Plan: draft" (denote-keywords-sort (list "work" "ideas")) 'org \(theirs.appendingPathComponent("work/").path.debugDescription)
                      "2026-10-11 09:30" 'plan "Part One")
              (save-buffer))
            """)
        let date = try #require(RoamActions.date("2026-10-11 09:30"))
        _ = try DenoteNote.create(title: "Q4 Plan: draft", keywords: ["work", "ideas"], in: ours.appendingPathComponent("work").path, roots: [ours.path],
                                  now: date, signature: "Part One", template: template)
        let names = try FileManager.default.contentsOfDirectory(atPath: theirs.appendingPathComponent("work").path)
        #expect(names.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ours.appendingPathComponent("work").path) == names)
        for name in names {
            #expect(try String(contentsOf: ours.appendingPathComponent("work/" + name), encoding: .utf8)
                == String(contentsOf: theirs.appendingPathComponent("work/" + name), encoding: .utf8), "\(name)")
        }
    }

    /// denote-org's dynamic blocks, each updated in a note by Emacs and by orgstar.
    @Test(.enabled(if: has("denote-org"))) func blocksMatchDenoteOrg() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let notes = [
            "20261001T090000--alpha-note__emacs_work.org": "#+title:      Alpha Note\n#+filetags:   :emacs:work:\n#+identifier: 20261001T090000\n\n* First\nSee [[denote:20261119T120000][Current]].\n** Deeper\n#+begin_src sh\necho\n#+end_src\n",
            "20261002T090000==1a--beta__emacs.org": "#+title:      Beta\n#+filetags:   :emacs:\n#+identifier: 20261002T090000\n\nBeta body.\n",
            "sub/20260930T090000--gamma-in-sub__work.org": "#+title:      Gamma in Sub\n#+filetags:   :work:\n#+identifier: 20260930T090000\n\nGamma links [[denote:20261119T120000::#top][here]].\n",
            "20261003T090000--delta__misc.md": "---\ntitle: Delta\n---\n\nDelta.\n",
            "plain.org": "* Not a note\n",
            "20261004T090000==1--root__seq.org": "#+title:      Root\n\nR\n",
            "20261005T090000==1=1--first__seq.org": "#+title:      First\n\nF\n",
            "20261006T090000==1=2--second__seq.org": "#+title:      Second\n\nS\n",
            "20261007T090000==1=1=1--deep__seq.org": "#+title:      Deep\n\nD\n",
            "20261008T090000==2--other__seq.org": "#+title:      Other\n\nO\n",
        ]
        for (name, text) in notes { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let current = dir.appendingPathComponent("20261119T120000--current.org")
        let head = "#+title:      Current\n#+identifier: 20261119T120000\n\nAlready: [[denote:20261002T090000][Beta]]\n\n"
        let blocks = [
            "denote-links :regexp \"_emacs\"",
            "denote-links :regexp \".\" :sort-by-component title :reverse-sort t",
            "denote-links :regexp \"_work\" :id-only t",
            "denote-links :regexp \"_work\" :include-date t :block-name \"mine\"",
            "denote-links :regexp \".\" :not-regexp \"sub\" :sort-by-component signature",
            "denote-missing-links :regexp \".\"",
            "denote-backlinks",
            "denote-files :regexp \"beta\"",
            "denote-files :regexp \"_work\" :no-front-matter t :add-links t :file-separator t",
            "denote-files :regexp \"_work\" :no-front-matter 2",
            "denote-files-as-headings :regexp \"_work\"",
            "denote-files-as-headings :regexp \"_work\" :add-links t :exclude-tags t",
            "denote-sequence :sequence \"1\" :depth 2",
            "denote-sequence :sequence \"1=1\"",
            "denote-sequence :sequence \"\"",
        ]
        let paths = Self.loadPath!.map(\.debugDescription).joined(separator: " ")
        for block in blocks {
            let text = head + "#+BEGIN: \(block)\nold\n#+END:\n"
            try text.write(to: current, atomically: true, encoding: .utf8)
            let theirs = try DailiesTests.emacs("""
                (progn (setq load-path (append (list \(paths)) load-path) coding-system-for-read 'utf-8 coding-system-for-write 'utf-8)
                  (require 'org) (require 'denote) (require 'denote-sequence nil t) (require 'denote-org)
                  (setq denote-directory \((dir.path + "/").debugDescription))
                  (find-file \(current.path.debugDescription))
                  (goto-char (point-min)) (re-search-forward "^#\\\\+BEGIN:") (beginning-of-line)
                  (org-update-dblock)
                  (princ (buffer-string)))
                """)
            var options = EditingOptions.org
            options.filePath = current.path
            options.denoteDirectories = [dir.path]
            let begin = (text as NSString).range(of: "#+BEGIN:").location
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [begin..<begin], options: options)
            var ours = text
            if case .commit(let result) = UpdateDynamicBlock().run(in: context) {
                for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { ours = edit.apply(to: ours) }
            } else {
                ours = "failed"
            }
            #expect(ours == theirs, "\(block)\nours:\n\(ours)\ntheirs:\n\(theirs)")
        }
    }

    /// denote-sequence's new parents, children and siblings, relatives and conversions, for
    /// notes in each scheme, from Emacs and from orgstar.
    @Test(.enabled(if: has("denote-sequence"))) func sequencesMatchDenoteSequence() throws {
        let sets: [(DenoteSequence.Scheme, [String])] = [
            (.numeric, ["1", "1=1", "1=2", "1=1=1", "1=1=1=1", "2", "3=1", "10", "10=9", "10=10", "2=1=5"]),
            (.alphanumeric, ["1", "1a", "1b", "1a1", "1a2", "1z", "2", "2a1a", "3", "1za"]),
            (.alphanumericDelimited, ["1", "1=a", "1=b", "1=a1b", "1=a1b=1", "2", "2=a", "1=a2"]),
        ]
        let paths = Self.loadPath!.map(\.debugDescription).joined(separator: " ")
        for (scheme, sequences) in sets {
            let dir = try Self.folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            for (index, sequence) in sequences.enumerated() {
                try "x\n".write(to: dir.appendingPathComponent(String(format: "20260101T%06d==%@--n%d.org", index, sequence, index)), atomically: true, encoding: .utf8)
            }
            let names = sequences.map(\.debugDescription).joined(separator: " ")
            let relations = DenoteSequence.Relation.allCases.map(\.rawValue).joined(separator: " ")
            let theirs = try DailiesTests.emacs("""
                (progn (setq load-path (append (list \(paths)) load-path))
                  (require 'denote) (require 'denote-sequence)
                  (setq denote-directory \((dir.path + "/").debugDescription) denote-sequence-scheme '\(scheme.rawValue))
                  (defmacro try (form) `(condition-case nil ,form (error "ERR")))
                  (princ (format "parent %s\\n" (try (denote-sequence-get-new 'parent))))
                  (dolist (s (list \(names)))
                    (princ (format "child %s %s\\n" s (try (denote-sequence-get-new 'child s))))
                    (princ (format "sibling %s %s\\n" s (try (denote-sequence-get-new 'sibling s))))
                    (dolist (target '(numeric alphanumeric alphanumeric-delimited))
                      (princ (format "convert %s %s %s\\n" s target (try (denote-sequence-make-conversion s target)))))
                    (dolist (relation '(\(relations)))
                      (princ (format "%s %s %s\\n" relation s
                                     (try (let ((found (denote-sequence-get-relative s relation)))
                                            (string-join (sort (mapcar #'file-name-nondirectory (if (stringp found) (list found) found)) #'string<) ","))))))))
                """)
            let model = DenoteSequence(scheme: scheme)
            let files = DenoteSequence.files(DenoteBlocks.files(in: [dir.path]).map(\.path))
            let all = files.map(\.sequence)
            func attempt(_ body: () throws -> String) -> String { (try? body()) ?? "ERR" }
            var ours = "parent \(attempt { try model.newParent(among: all) })\n"
            for s in sequences {
                ours += "child \(s) \(attempt { try model.newChild(of: s, among: all) })\n"
                ours += "sibling \(s) \(attempt { try model.newSibling(of: s, among: all) })\n"
                for target in DenoteSequence.Scheme.allCases {
                    ours += "convert \(s) \(target.rawValue) \(attempt { try model.converted(s, to: target) })\n"
                }
                for relation in DenoteSequence.Relation.allCases {
                    ours += "\(relation.rawValue) \(s) \(attempt { try model.relatives(of: s, relation, in: files).map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ",") })\n"
                }
            }
            let theirLines = theirs.split(separator: "\n").map(String.init), ourLines = ours.split(separator: "\n").map(String.init)
            #expect(theirLines.count == ourLines.count, "\(scheme)\n\(theirs)")
            for (a, b) in zip(ourLines, theirLines) where a != b {
                Issue.record("\(scheme): ours \(a) | theirs \(b)")
            }
        }
    }

    /// `denote-rename-file` with a new title, keywords, signature and date: on a note, on one
    /// whose signature goes, and on a file without front matter or identifier.
    @Test(.enabled(if: enabled)) func renamesMatchDenote() throws {
        let theirs = try Self.folder(), ours = try Self.folder()
        defer { try? FileManager.default.removeItem(at: theirs); try? FileManager.default.removeItem(at: ours) }
        let files = [
            "20261011T120000--old-title__x.org": "#+title:      Old Title\n#+date:       [2026-10-11 Sun 12:00]\n#+filetags:   :x:\n#+identifier: 20261011T120000\n#+startup: overview\n\nBody\n",
            "20261011T130000==zz--has-sig.org": "#+title:      Has Sig\n#+date:       [2026-10-11 Sun 12:00]\n#+filetags:   \n#+identifier: 20261011T130000\n#+signature:  zz\n\nBody\n",
            "plain.org": "* Heading\nNo front matter\n",
        ]
        for dir in [theirs, ours] { for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) } }
        let renames: [(file: String, title: String, keywords: [String], signature: String)] = [
            ("20261011T120000--old-title__x.org", "New Title", ["zeta", "Alpha"], "Part One"),
            ("20261011T130000==zz--has-sig.org", "Has Sig", [], ""),
            ("plain.org", "Plain Note", ["k"], ""),
        ]
        let calls = renames.map { r in
            "(denote-rename-file \(theirs.appendingPathComponent(r.file).path.debugDescription) \(r.title.debugDescription) (list \(r.keywords.map(\.debugDescription).joined(separator: " "))) \(r.signature.debugDescription) \"2026-10-11 12:00:00\" \((Denote.identifier(ofFile: r.file) ?? "").debugDescription))"
        }.joined(separator: "\n")
        try Self.denote(theirs, calls + "\n(save-some-buffers t)")
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 12))!
        for r in renames {
            let path = ours.appendingPathComponent(r.file).path
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let (target, rewritten) = DenoteNote.renaming(path, text: text, title: r.title, keywords: r.keywords, signature: r.signature, date: date, roots: [ours.path])
            try rewritten.write(toFile: path, atomically: true, encoding: .utf8)
            if target != path { try FileManager.default.moveItem(atPath: path, toPath: target) }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: theirs.path).sorted()
        #expect(try FileManager.default.contentsOfDirectory(atPath: ours.path).sorted() == names)
        for name in names {
            #expect(try String(contentsOf: ours.appendingPathComponent(name), encoding: .utf8)
                == String(contentsOf: theirs.appendingPathComponent(name), encoding: .utf8), "\(name)")
        }
    }
}
