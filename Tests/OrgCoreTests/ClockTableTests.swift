import Foundation
import Testing
@testable import OrgCore

struct ClockTableTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let body = """
        * Project Alpha :work:
        :PROPERTIES:
        :Effort:   3:00
        :END:
        ** TODO Design the [[https://x.org][interface]] [1/2]
        :LOGBOOK:
        CLOCK: [2026-09-07 Mon 09:00]--[2026-09-07 Mon 11:30] =>  2:30
        CLOCK: [2026-09-09 Wed 23:00]--[2026-09-10 Thu 01:00] =>  2:00
        :END:
        *** A very long heading title that goes on and on beyond the narrowing width
        CLOCK: [2026-09-10 Thu 08:00]--[2026-09-10 Thu 08:45] =>  0:45
        ** Write code
        CLOCK: [2026-08-30 Sun 10:00]--[2026-08-30 Sun 12:00] =>  2:00
        CLOCK: => 1:15
        * COMMENT Beta
        CLOCK: [2026-09-08 Tue 14:00]--[2026-09-09 Wed 16:00] => 26:00
        * Untouched

        """

    static let params = [
        ":scope file :maxlevel 2", ":maxlevel 3 :emphasize t", ":maxlevel 1", ":block thisweek", ":block lastweek",
        ":block today :maxlevel 3", ":block 2026-09", ":tstart \"<2026-09-08>\" :tend \"<2026-09-10>\"",
        ":link t :maxlevel 3", ":narrow 20! :maxlevel 3", ":tags t :level t :maxlevel 3", ":properties (\"Effort\") :formula %",
        ":indent nil :maxlevel 3", ":block yesterday", ":block 2026-W36 :maxlevel 3", ":fileskip0 t :block 2025",
        ":maxlevel nil",
        ":match \"work\" :maxlevel 3", ":match \"-work\" :maxlevel 3", ":match \"TODO=\\\"TODO\\\"\" :maxlevel 3",
        ":match \"LEVEL=2\" :maxlevel 3", ":block 2026-09 :step week", ":block 2026-09 :step day :stepskip0 t",
        ":tstart \"<2026-08-25>\" :tend \"<2026-09-15>\" :step week :wstart 0", ":block 2026 :step month :stepskip0 t",
        ":block 2026 :step quarter", ":block 2026-09 :step semimonth :stepskip0 t",
    ]

    static func ours(_ text: String, caret: Int, command: any OrgCommand, answers: [String: String] = [:]) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret],
                                  now: Date(timeIntervalSince1970: 1_789_000_000), calendar: utc, answers: answers)
        switch command.run(in: context) {
        case .commit(let result):
            var new = text
            for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
            return new
        case .failed(let message): return "failed: \(message)"
        default: return "other"
        }
    }

    @Test(.enabled(if: oracle))
    func updatesLikeOrgUpdateDblock() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for param in Self.params {
            let text = "#+BEGIN: clocktable \(param)\nold contents\n#+END:\n" + Self.body
            cases.append(EmacsOracle.Case(text: text, point: 1, form: frozenClock(1_789_000_000, "(org-update-dblock)")))
            ours.append(Self.ours(text, caret: 0, command: UpdateDynamicBlock()))
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine == theirs.text, "\(Self.params[i])\nours:\n\(mine)\nemacs:\n\(theirs.text) \(theirs.error)")
        }
    }

    @Test(.enabled(if: oracle))
    func reportsLikeOrgClockReport() throws {
        let text = "Intro\n" + Self.body
        let ns = text as NSString
        let points = [ns.range(of: "Intro").location + 2, ns.range(of: "** Write").location + 3, ns.range(of: "CLOCK: [2026-09-07").location]
        let cases = points.map { EmacsOracle.Case(text: text, point: EmacsOracle.point($0, in: text), form: frozenClock(1_789_000_000, "(org-clock-report)")) }
        let ours = points.map { Self.ours(text, caret: $0, command: ClockReportTable()) }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(cases)).enumerated() {
            #expect(mine == theirs.text, "at \(points[i])\nours:\n\(mine)\nemacs:\n\(theirs.text) \(theirs.error)")
        }
    }

    @Test(.enabled(if: oracle))
    func setsEffortLikeOrgSetEffort() throws {
        let text = "* Task\n* Other\n:PROPERTIES:\n:Effort:   1:00\n:END:\n"
        let cases = [(0, "0:30"), (8, "2:00")].map { EmacsOracle.Case(text: text, point: $0.0 + 1, form: "(org-set-effort nil \"\($0.1)\")") }
        let ours = [(0, "0:30"), (8, "2:00")].map { Self.ours(text, caret: $0.0, command: SetEffort(), answers: ["effort": $0.1]) }
        #expect(ours == (try EmacsOracle.run(cases)).map(\.text))
    }

    @Test func durations() {
        #expect(ClockTable.duration(0) == "0:00" && ClockTable.duration(95) == "1:35" && ClockTable.duration(1560) == "1d 2:00")
    }
}

/// Clock tables over several files, against Emacs visiting the same files.
struct ClockTableScopeTests {
    static let files: [(String, String)] = [
        ("a.org", """
        #+BEGIN: clocktable
        #+END:
        * Alpha :work:
        CLOCK: [2026-09-07 Mon 09:00]--[2026-09-07 Mon 10:00] =>  1:00
        ** Alpha child
        CLOCK: [2026-09-08 Tue 09:00]--[2026-09-08 Tue 09:30] =>  0:30
        * Beta
        :PROPERTIES:
        :ARCHIVE: old.org::
        :END:

        """),
        ("a.org_archive", "* Archived :work:\nCLOCK: [2026-09-02 Wed 09:00]--[2026-09-02 Wed 11:00] =>  2:00\n"),
        ("old.org", "* Old entry\nCLOCK: [2026-09-03 Thu 09:00]--[2026-09-03 Thu 09:15] =>  0:15\n"),
        ("b.org", "#+TITLE: Bee file\n* Bee :work:\nCLOCK: [2026-09-09 Wed 13:00]--[2026-09-09 Wed 15:00] =>  2:00\n* Idle\n"),
        ("sub/c.org", "* Sea\nCLOCK: [2026-08-01 Sat 13:00]--[2026-08-01 Sat 14:00] =>  1:00\n"),
    ]

    static let params = [
        ":scope agenda", ":scope agenda-with-archives", ":scope file-with-archives", ":scope (\"b.org\" \"sub/c.org\")",
        ":scope agenda :hidefiles t", ":scope agenda :block 2026-09 :fileskip0 t", ":scope (\"b.org\" \"sub/c.org\") :block 2026-09 :fileskip0 t",
        ":scope agenda :link t", ":scope agenda :filetitle t :formula %", ":scope agenda :level t :tags t",
        ":scope agenda :block 2026-09 :step week :stepskip0 t", ":scope agenda :match \"work\"",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func scopesLikeOrg() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-clocktable-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: folder) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        for param in Self.params {
            for (name, text) in Self.files {
                let url = folder.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (name == "a.org" ? text.replacingOccurrences(of: "#+BEGIN: clocktable\n", with: "#+BEGIN: clocktable \(param)\n") : text)
                    .write(to: url, atomically: true, encoding: .utf8)
            }
            let a = folder.appendingPathComponent("a.org").path
            let b = folder.appendingPathComponent("b.org").path
            let form = """
            (progn
              (require 'org) (require 'org-clock)
              (add-to-list 'auto-mode-alist '("\\\\.org_archive\\\\'" . org-mode))
              (setq org-agenda-files (list "\(a)" "\(b)"))
              (find-file "\(a)")
              (goto-char (point-min))
              \(frozenClock(1_789_000_000, "(org-update-dblock)"))
              (princ (buffer-string)))
            """
            let emacs = try EmacsOracle.run(["-Q", "--batch", "--eval", form], environment: ["TZ": "UTC"])
            let text = try String(contentsOfFile: a, encoding: .utf8)
            var options = EditingOptions.org
            options.filePath = a
            options.agendaFiles = [a, b]
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [0..<0],
                                      now: Date(timeIntervalSince1970: 1_789_000_000), calendar: utc, options: options)
            var ours = text
            if case .commit(let result) = UpdateDynamicBlock().run(in: context) {
                for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { ours = edit.apply(to: ours) }
            } else {
                ours = "failed"
            }
            #expect(emacs.hasSuffix(ours), "\(param)\nours:\n\(ours)\nemacs:\n\(emacs)")
        }
    }
}

extension ClockTableScopeTests {
    /// A folder in a `:scope` list gives its org files; Emacs takes only files there.
    @Test func folderScopes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-clocktable-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "* Sea\nCLOCK: [2026-08-01 Sat 13:00]--[2026-08-01 Sat 14:00] =>  1:00\n".write(to: folder.appendingPathComponent("sub/c.org"), atomically: true, encoding: .utf8)
        try "* Dee\nCLOCK: [2026-08-02 Sun 13:00]--[2026-08-02 Sun 13:30] =>  0:30\n".write(to: folder.appendingPathComponent("sub/d.org"), atomically: true, encoding: .utf8)
        let text = "#+BEGIN: clocktable :scope (\"sub\")\n#+END:\n"
        var options = EditingOptions.org
        options.filePath = folder.appendingPathComponent("a.org").path
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [0..<0], options: options)
        guard case .commit(let result) = UpdateDynamicBlock().run(in: context) else { Issue.record("no table"); return }
        let table = result.edits[0].apply(to: text).replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        #expect(table.contains("| c.org | *File time* | *1:00*") && table.contains("| d.org | *File time* | *0:30*"), "\(table)")
        #expect(table.contains("*1:30*"))
    }
}
