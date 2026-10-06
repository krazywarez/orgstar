import Foundation
import Testing
@testable import OrgCore

struct CaptureTests {
    struct Case {
        var file: String
        var template: CaptureTemplate
        var typed: String
    }

    static func lisp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Captures each case in `emacs --batch`: the target file afterwards.
    static func emacs(_ cases: [Case], seconds: Int) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var forms: [String] = []
        for (i, c) in cases.enumerated() {
            let path = folder.appendingPathComponent("target\(i).org").path
            try c.file.write(toFile: path, atomically: true, encoding: .utf8)
            let target: String
            var properties = c.template.prepend ? " :prepend t" : ""
            let o = c.template.options
            if let n = o.emptyLines { properties += " :empty-lines \(n)" }
            if let n = o.emptyLinesBefore { properties += " :empty-lines-before \(n)" }
            if let n = o.emptyLinesAfter { properties += " :empty-lines-after \(n)" }
            switch c.template.target {
            case .file: target = "(file \(lisp(path)))"
            case .headline(_, let h): target = "(file+headline \(lisp(path)) \(lisp(h)))"
            case .outline(_, let p): target = "(file+olp \(lisp(path)) \(p.map(lisp).joined(separator: " ")))"
            case .datetree(_, let p, let tree):
                target = "(file+olp+datetree \(lisp(path)) \(p.map(lisp).joined(separator: " ")))"
                properties += " :tree-type \(tree.rawValue)"
            case .id(let id): target = "(id \(lisp(id)))"
            case .clock, .heading: target = "(clock)"
            }
            forms.append("""
            (let ((org-capture-templates '(("x" "case" \(c.template.kind.rawValue) \(target) \(lisp(c.template.template))\(properties))))
                  (path \(lisp(path))))
              (cl-letf (((symbol-function 'org-id-find)
                         (lambda (id &rest _)
                           (with-current-buffer (find-file-noselect path)
                             (save-excursion
                               (goto-char (point-min))
                               (when (re-search-forward (concat "^[ \t]*:ID:[ \t]+" (regexp-quote id) "[ \t]*$") nil t)
                                 (org-back-to-heading t)
                                 (cons path (point))))))))
                (org-capture nil "x"))
              (insert \(lisp(c.typed)))
              (org-capture-finalize)
              (with-current-buffer (find-buffer-visiting \(lisp(path)))
                (push (buffer-substring-no-properties (point-min) (point-max)) results)))
            """)
        }
        let output = folder.appendingPathComponent("out.json")
        let script = folder.appendingPathComponent("capture.el")
        try """
        ;;; -*- lexical-binding: t -*-
        (require 'org)
        (require 'org-capture)
        (require 'org-id)
        (require 'json)
        (setq org-adapt-indentation nil)
        (defvar results nil)
        \(frozenClock(seconds, "(progn " + forms.joined(separator: "\n") + ")"))
        (with-temp-file \(lisp(output.path)) (insert (json-encode (vconcat (nreverse results)))))
        """.write(to: script, atomically: true, encoding: .utf8)
        let log = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["TZ": "UTC"])
        guard FileManager.default.fileExists(atPath: output.path) else { throw EmacsOracle.EvaluateError(log: log) }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: output))
    }

    static func ours(_ c: Case, now: Date) -> String {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard case .success(let filled) = Capture.fill(c.template.template, context: CaptureContext(now: now, calendar: utc)) else { return "fill failed" }
        var text = filled.text
        let index = String.Index(utf16Offset: filled.cursor, in: text)
        text.insert(contentsOf: c.typed, at: index)
        switch Capture.place(text, template: c.template, in: c.file, now: now, calendar: utcCalendar) {
        case .success(let result): return result
        case .failure(.message(let message)): return "failed: \(message)"
        }
    }

    static let files = [
        "#+TITLE: Todo\n* Inbox\n** TODO Old\n* Later\nText\n",
        "* Inbox\n\n** TODO Old\n\n* Later\n",
        "* Inbox\n",
        "* Inbox",
        "",
        "Preamble\n* Other\n",
        "* Inbox\nSome notes.\n- one\n- two\n\n** Child\n",
        "* Projects\n** Work\n*** Active\n** Home\n",
        "* Inbox\n:PROPERTIES:\n:ID: x\n:END:\nBody\n",
    ]

    static let templates: [CaptureTemplate] = [
        CaptureTemplate(key: "x", name: "", target: .headline(file: "", headline: "Inbox"), template: "* TODO %?\n%i\n%a"),
        CaptureTemplate(key: "x", name: "", target: .headline(file: "", headline: "Inbox"), template: "* %u %?\n%i\n%a"),
        CaptureTemplate(key: "x", name: "", target: .headline(file: "", headline: "Inbox"), template: "* TODO %?", prepend: true),
        CaptureTemplate(key: "x", name: "", target: .headline(file: "", headline: "Missing"), template: "* %?"),
        CaptureTemplate(key: "x", name: "", target: .file(""), template: "* Note %U\n%?"),
        CaptureTemplate(key: "x", name: "", target: .file(""), template: "** Deep %?", prepend: true),
        CaptureTemplate(key: "x", name: "", target: .headline(file: "", headline: "Inbox"), template: "Plain %? text", ),
        CaptureTemplate(key: "x", name: "", kind: .plain, target: .headline(file: "", headline: "Inbox"), template: "Plain line %?"),
        CaptureTemplate(key: "x", name: "", kind: .plain, target: .file(""), template: "%<%Y-%m-%d>: %?"),
        CaptureTemplate(key: "x", name: "", kind: .item, target: .headline(file: "", headline: "Inbox"), template: "%?"),
        CaptureTemplate(key: "x", name: "", kind: .checkitem, target: .headline(file: "", headline: "Inbox"), template: "[ ] %?"),
        CaptureTemplate(key: "x", name: "", target: .outline(file: "", path: ["Projects", "Work"]), template: "* TODO %?\n  Added %T"),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let seconds = 1_789_000_000
        var cases: [Case] = []
        for template in Self.templates {
            for file in Self.files {
                if case .outline = template.target, !file.contains("Projects") { continue }
                if template.kind == .item || template.kind == .checkitem, !file.contains("Inbox") { continue }
                cases.append(Case(file: file, template: template, typed: "Buy milk"))
            }
        }
        let emacs = try Self.emacs(cases, seconds: seconds)
        let now = Date(timeIntervalSince1970: Double(seconds))
        for (c, expected) in zip(cases, emacs) {
            let mine = Self.ours(c, now: now)
            #expect(mine == expected, "\(c.template.template.debugDescription) \(c.template.kind) prepend \(c.template.prepend) into \(c.file.debugDescription)\nours:\n\(mine.debugDescription)\nemacs:\n\(expected.debugDescription)")
        }
    }

    static let datetreeFiles = [
        "",
        "#+TITLE: Journal\n",
        "* 2026\n** 2026-09 September\n*** 2026-09-01 Tuesday\nOld\n*** 2026-09-30 Wednesday\n** 2026-11 November\n* 2027\n",
        "* 2025\n\n** 2025-01 January\n\n*** 2025-01-01 Wednesday\n\nNew year\n\n* Other\n",
        "Notes before.\n\n* Journal\n** 2026\n*** 2026-09 September\n* Tasks\n** TODO Thing\n",
        "* Journal\n:PROPERTIES:\n:ID: journal-id\n:END:\n* Tasks\n",
        "* 2026\n** 2026-W36\n*** 2026-09-01 Tuesday\n** 2026-W38\n",
    ]

    static let datetreeTemplates: [CaptureTemplate] = [
        CaptureTemplate(key: "x", name: "", target: .datetree(file: "", path: [], tree: .day), template: "* %?"),
        CaptureTemplate(key: "x", name: "", target: .datetree(file: "", path: [], tree: .week), template: "* %U %?"),
        CaptureTemplate(key: "x", name: "", target: .datetree(file: "", path: [], tree: .month), template: "* %?"),
        CaptureTemplate(key: "x", name: "", target: .datetree(file: "", path: ["Journal"], tree: .day), template: "* %?"),
        CaptureTemplate(key: "x", name: "", kind: .plain, target: .datetree(file: "", path: [], tree: .day), template: "%U %?"),
        CaptureTemplate(key: "x", name: "", kind: .item, target: .datetree(file: "", path: [], tree: .day), template: "%?"),
        CaptureTemplate(key: "x", name: "", target: .datetree(file: "", path: [], tree: .day), template: "* %?", options: .init(prepend: true)),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil), arguments: [1_789_000_000, 1_798_804_800])
    func datetreesMatchEmacs(seconds: Int) throws {
        var cases: [Case] = []
        for template in Self.datetreeTemplates {
            for file in Self.datetreeFiles {
                if case .datetree(_, let path, _) = template.target, !path.isEmpty, !file.contains("* Journal") { continue }
                cases.append(Case(file: file, template: template, typed: "Entry"))
            }
        }
        let emacs = try Self.emacs(cases, seconds: seconds)
        let now = Date(timeIntervalSince1970: Double(seconds))
        for (c, expected) in zip(cases, emacs) {
            let mine = Self.ours(c, now: now)
            #expect(mine == expected, "\(c.template.target) \(c.template.kind) into \(c.file.debugDescription)\nours:\n\(mine.debugDescription)\nemacs:\n\(expected.debugDescription)")
        }
    }

    static let optionTemplates: [CaptureTemplate] = [
        CaptureTemplate(key: "x", name: "", target: .id("journal-id"), template: "* %?"),
        CaptureTemplate(key: "x", name: "", target: .headline(file: "", headline: "Inbox"), template: "* %?", options: .init(emptyLines: 1)),
        CaptureTemplate(key: "x", name: "", target: .headline(file: "", headline: "Inbox"), template: "* %?", options: .init(emptyLinesBefore: 2, emptyLinesAfter: 1)),
        CaptureTemplate(key: "x", name: "", target: .file(""), template: "* %?", options: .init(prepend: true, emptyLinesAfter: 1)),
        CaptureTemplate(key: "x", name: "", kind: .plain, target: .headline(file: "", headline: "Inbox"), template: "%?", options: .init(emptyLines: 1)),
        CaptureTemplate(key: "x", name: "", kind: .item, target: .file(""), template: "%?", options: .init(emptyLines: 1)),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func targetsAndEmptyLinesMatchEmacs() throws {
        var cases: [Case] = []
        let files = ["* Journal\n:PROPERTIES:\n:ID: journal-id\n:END:\nText\n** Old\n* Inbox\n", "* Inbox\n\n** Old\n\n* Later\n", "Preamble\n* Inbox\nBody\n"]
        for template in Self.optionTemplates {
            for file in files {
                if case .id = template.target, !file.contains("journal-id") { continue }
                cases.append(Case(file: file, template: template, typed: "Entry"))
            }
        }
        let seconds = 1_789_000_000
        let emacs = try Self.emacs(cases, seconds: seconds)
        for (c, expected) in zip(cases, emacs) {
            let mine = Self.ours(c, now: Date(timeIntervalSince1970: Double(seconds)))
            #expect(mine == expected, "\(c.template.target) \(c.template.kind) \(c.template.options) into \(c.file.debugDescription)\nours:\n\(mine.debugDescription)\nemacs:\n\(expected.debugDescription)")
        }
    }

    @Test func fillsPrompts() {
        let template = "* %^{Title|untitled} for %^{Who}\n%\\1 again"
        #expect(Capture.questions(template) == [
            Capture.Question(prompt: "Title", defaultValue: "untitled", choices: []),
            Capture.Question(prompt: "Who", defaultValue: "", choices: []),
        ])
        guard case .success(let filled) = Capture.fill(template, context: CaptureContext(), answers: ["", "me"]) else {
            Issue.record("fill failed")
            return
        }
        #expect(filled.text == "* untitled for me\nuntitled again\n")
    }
}
