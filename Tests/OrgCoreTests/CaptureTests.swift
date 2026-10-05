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
            switch c.template.target {
            case .file: target = "(file \(lisp(path)))"
            case .headline(_, let h): target = "(file+headline \(lisp(path)) \(lisp(h)))"
            case .outline(_, let p): target = "(file+olp \(lisp(path)) \(p.map(lisp).joined(separator: " ")))"
            }
            forms.append("""
            (let ((org-capture-templates '(("x" "case" \(c.template.kind.rawValue) \(target) \(lisp(c.template.template))\(c.template.prepend ? " :prepend t" : "")))))
              (org-capture nil "x")
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
        (require 'json)
        (setq org-adapt-indentation nil)
        (defvar results nil)
        \(frozenClock(seconds, "(progn " + forms.joined(separator: "\n") + ")"))
        (with-temp-file \(lisp(output.path)) (insert (json-encode (vconcat (nreverse results)))))
        """.write(to: script, atomically: true, encoding: .utf8)
        _ = try EmacsOracle.run(["-Q", "--batch", "-l", script.path], environment: ["TZ": "UTC"])
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: output))
    }

    static func ours(_ c: Case, now: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard case .success(let filled) = Capture.fill(c.template.template, context: CaptureContext(now: now, calendar: utc)) else { return "fill failed" }
        var text = filled.text
        let index = String.Index(utf16Offset: filled.cursor, in: text)
        text.insert(contentsOf: c.typed, at: index)
        switch Capture.place(text, template: c.template, in: c.file) {
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
