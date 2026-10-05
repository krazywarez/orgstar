import Foundation
import Testing
@testable import OrgCore

struct ClockTests {
    static let texts = [
        "* TODO Task\n",
        "* TODO Task\nBody text.\n",
        "* Task\nSCHEDULED: <2026-10-05 Mon>\n:PROPERTIES:\n:ID: x\n:END:\nBody\n",
        "* Task\n:LOGBOOK:\nCLOCK: [2026-10-04 Sun 09:00]--[2026-10-04 Sun 10:00] =>  1:00\n:END:\nNotes\n",
        "* Task\nCLOCK: [2026-10-04 Sun 09:00]--[2026-10-04 Sun 10:00] =>  1:00\nNotes\n",
        "* Task\n** Child\nChild body\n* Next\n",
        "* Task",
        "Preamble\n* Task\n- item\n",
        "* Task\n:LOGBOOK:\n- State \"DONE\" from \"TODO\" [2026-10-01 Thu 10:00]\n:END:\n",
    ]

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func run(_ command: any OrgCommand, _ text: String, caret: Int, at seconds: Int) -> (text: String, caret: Int, failure: String?) {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], now: Date(timeIntervalSince1970: Double(seconds)), calendar: Self.utc)
        switch command.run(in: context) {
        case .commit(let result):
            var new = text
            for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
            return (new, result.selection?.first?.lowerBound ?? caret, nil)
        case .failed(let message): return (text, caret, message)
        default: return (text, caret, "other")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let t1 = 1_789_000_000   // Thu 2026-09-10 00:26
        let t2 = t1 + 3 * 3600 + 17 * 60 + 42
        var cases: [EmacsOracle.Case] = []
        var ours: [(String, String)] = []
        for text in Self.texts {
            let caret = (text as NSString).range(of: "Task").location
            for mode in ["out", "cancel"] {
                // Clock in at t1, then out (or cancel) at t2.
                let first = run(ClockIn(), text, caret: caret, at: t1)
                guard let start = ClockIn.runningStart(in: first.text, near: caret) else {
                    ours.append(("no running clock: \(first.failure ?? "")", text))
                    cases.append(EmacsOracle.Case(text: text, point: 1, form: "nil"))
                    continue
                }
                let second = run(ClockOut(start: start, cancel: mode == "cancel"), first.text, caret: first.caret, at: t2)
                ours.append((second.text, first.text))
                let out = mode == "cancel" ? "(org-clock-cancel)" : "(org-clock-out)"
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
                (progn
                  (require 'org-clock)
                  (setq org-clock-persist nil org-clock-idle-time nil org-clock-auto-clock-resolution nil org-clock-into-drawer t)
                  \(frozenClock(t1, "(org-clock-in)"))
                  (setq orgstar-after-in (buffer-substring-no-properties (point-min) (point-max)))
                  \(frozenClock(t2, out)))
                """))
            }
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.0 == theirs.text, "case \(i) \(cases[i].form.contains("cancel") ? "cancel" : "out")\n\(cases[i].text.debugDescription)\nafter in (ours): \(mine.1.debugDescription)\nours:  \(mine.0.debugDescription)\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }
}


struct ClockReportTests {
    static let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/doom/config.el")

    static let sample = """
    * TODO [#A] Audit work :work:
    :LOGBOOK:
    CLOCK: [2026-02-20 Fri 10:00]--[2026-02-20 Fri 16:00] =>  6:00
    CLOCK: [2026-02-17 Tue 16:22]--[2026-02-17 Tue 16:45] =>  0:23
    CLOCK: [2026-02-17 Tue 08:15]--[2026-02-17 Tue 08:50] =>  0:35
    :END:
    * Meetings
    :LOGBOOK:
    CLOCK: [2026-02-24 Tue 09:30]--[2026-02-24 Tue 10:00] =>  0:30
    CLOCK: [2026-03-02 Mon 09:00]
    CLOCK: [2026-02-17 Tue 09:28]--[2026-02-17 Tue 09:55] =>  0:27
    :END:
    """

    /// Your own `tr/generate-report`, loaded from config.el in batch Emacs.
    static func emacsReport(_ text: String, start: String?, end: String?) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("time.org")
        let output = folder.appendingPathComponent("report.org")
        try text.write(to: input, atomically: true, encoding: .utf8)
        func lisp(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "nil" }
        let script = folder.appendingPathComponent("tr.el")
        try """
        (require 'org)
        (require 'cl-lib)
        (require 'subr-x)
        (with-temp-buffer
          (insert-file-contents "\(config.path)")
          (goto-char (point-min))
          (condition-case nil
              (while t
                (let ((form (read (current-buffer))))
                  (when (and (eq (car-safe form) 'defun) (string-prefix-p "tr/" (symbol-name (cadr form))))
                    (eval form t))))
            (end-of-file nil)))
        (tr/generate-report "\(input.path)" "\(output.path)" \(lisp(start)) \(lisp(end)))
        """.write(to: script, atomically: true, encoding: .utf8)
        _ = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["TZ": "UTC"])
        return try String(contentsOf: output, encoding: .utf8)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: ClockReportTests.config.path) && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesYourReport() throws {
        var texts = [Self.sample]
        let work = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("git/cmc/work-notes/time.org")
        if let real = try? String(contentsOf: work, encoding: .utf8) { texts.append(real) }
        for text in texts {
            for (start, end) in [(nil, nil), ("2026-02-18", nil), (nil, "2026-02-20"), ("2026-02-17", "2026-02-17")] as [(String?, String?)] {
                let ours = ClockReport.timeReport(ClockReport.entries(text), start: start, end: end)
                let theirs = try Self.emacsReport(text, start: start, end: end)
                #expect(ours == theirs, "\(start ?? "-")..\(end ?? "-")\nours:\n\(ours)\ntheirs:\n\(theirs)")
            }
        }
    }
}
