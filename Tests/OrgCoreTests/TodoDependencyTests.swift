import Foundation
import Testing
@testable import OrgCore

struct TodoDependencyTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    /// Point is at the ¶.
    static let texts = [
        "* TODO A¶\n** TODO B\n",
        "* TODO A¶\n** DONE B\n",
        "* TODO A¶\n** B\n",
        "* TODO A¶\n** B\n*** TODO C\n",
        "* TODO A¶\n** DONE B\n*** TODO C\n",
        "* A¶\n** TODO B\n",
        "* TODO A\nbody¶\n** TODO [#A] B :x:y:\n",
        "* TODO A¶\n** TODO\n",
        "* TODO A¶\n** TODO B :ARCHIVE:\n",
        "* TODO A¶\n:PROPERTIES:\n:NOBLOCKING: t\n:END:\n** TODO B\n",
        "* TODO A¶\n:PROPERTIES:\n:NOBLOCKING: nil\n:END:\n** TODO B\n",
        "* TODO A¶\nSCHEDULED: <2026-10-05 Mon +1d>\n** TODO B\n",
        "* P\n:PROPERTIES:\n:ORDERED: t\n:END:\n** TODO A :x:\n** TODO B¶\n",
        "* P\n:PROPERTIES:\n:ORDERED: t\n:END:\n** DONE A\n** TODO B¶\n",
        "* P\n:PROPERTIES:\n:ORDERED: t\n:END:\n** TODO A¶\n** TODO B\n",
        "* P\n:PROPERTIES:\n:ORDERED: t\n:END:\n** A\n** TODO B¶\n",
        "* P\n:PROPERTIES:\n:ORDERED: nil\n:END:\n** TODO A\n** TODO B¶\n",
        "* P\n:PROPERTIES:\n:ORDERED:\n:END:\n** TODO A\n** TODO B¶\n",
        "* P\n:PROPERTIES:\n:ordered: t\n:END:\n** TODO A\n** TODO B¶\n",
        "* P\n:PROPERTIES:\n:ORDERED: t\n:END:\n** DONE A\n*** TODO A1\n** TODO B¶\n",
        "* G\n:PROPERTIES:\n:ORDERED: t\n:END:\n** P\n*** TODO A\n*** TODO B¶\n",
        "* G\n:PROPERTIES:\n:ORDERED: t\n:END:\n** TODO A\n** TODO P\n*** TODO B¶\n",
        "* G\n:PROPERTIES:\n:ORDERED: t\n:END:\n** TODO A\n** P\n*** TODO B¶\n",
        "* G\n:PROPERTIES:\n:ORDERED: t\n:END:\n** TODO A\n** TODO P\n*** TODO Q\n**** TODO B¶\n",
        "* G\n:PROPERTIES:\n:ORDERED: t\n:END:\n** DONE A\n** TODO P\n*** TODO B¶\n",
        "#+PROPERTY: ORDERED t\n* P\n** TODO A\n** TODO B¶\n",
        "* TODO A\n* TODO B¶\n",
        "* TODO A¶\n- [ ] x\n",
        "* TODO A¶\n- [X] x\n",
        "* TODO A¶\n- [-] x\n  - [X] y\n  - [ ] z\n",
        "* TODO A¶\n1. [@3] [ ] x\n",
        "* TODO A¶\n  + [ ] x\n",
        "* TODO A¶\n  * [ ] x\n",
        "* TODO A¶\n- [ ]\n",
        "* TODO A¶\nSome [ ] text\n",
        "* TODO A¶\n** B\n- [ ] x\n",
        "* TODO A¶\n#+begin_src text\n- [ ] x\n#+end_src\n",
        "* TODO A¶\n#+begin_example\n- [ ] x\n#+end_example\n",
        "* TODO A¶\n#+begin_quote\n- [ ] x\n#+end_quote\n",
        "* TODO A¶\n:NOTES:\n- [ ] x\n:END:\n",
        "* TODO A¶\n- [ ] x\n** TODO B\n",
        "* TODO A¶\n- [X] x\n** TODO B\n",
        "#+TODO: TODO NEXT | DONE CANCELED\n* NEXT A¶\n** TODO B\n",
        "#+TODO: TODO NEXT | DONE CANCELED\n* DONE A¶\n** TODO B\n",
        "#+TODO: TODO NEXT | DONE CANCELED\n* TODO A¶\n** NEXT B\n",
    ]

    static let settings: [(dependencies: Bool, checkboxes: Bool)] = [(true, false), (false, true), (true, true), (false, false)]

    static func place(_ marked: String) -> (text: String, caret: Int) {
        let caret = (marked as NSString).range(of: "¶").location
        return (marked.replacingOccurrences(of: "¶", with: ""), caret)
    }

    static func run(_ command: any OrgCommand, _ text: String, caret: Int, options: EditingOptions) -> (text: String, message: String?) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret],
                                  now: Date(timeIntervalSince1970: 1_789_000_000), calendar: utc, options: options)
        switch command.run(in: context) {
        case .commit(let result):
            let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
            let message = result.effects.compactMap { if case .message(let m) = $0 { m } else { nil } }.last
            return (new, message)
        case .failed(let message): return (text, message)
        default: return (text, "other")
        }
    }

    /// Runs `form` with the settings, failing with the last message it shows that `keep` keeps.
    static func form(_ form: String, dependencies: Bool, checkboxes: Bool, keep: String = "blocked") -> String {
        frozenClock(1_789_000_000, """
            (let (msgs)
              (setq org-blocker-hook nil org-enforce-todo-dependencies \(dependencies ? "t" : "nil")
                    org-enforce-todo-checkbox-dependencies \(checkboxes ? "t" : "nil") org-use-fast-todo-selection nil)
              (org-mode)
              (cl-letf (((symbol-function 'message) (lambda (f &rest a) (when f (push (apply #'format-message f a) msgs)) (car msgs))))
                \(form)
                (run-hooks 'post-command-hook))
              (let ((m (seq-find (lambda (s) (string-match-p \(lispString(keep)) s)) msgs))) (when m (error "%s" m))))
            """)
    }

    @Test(.enabled(if: oracle))
    func blocksLikeOrgTodo() throws {
        let changes: [(String, any OrgCommand, String)] = [
            ("DONE", SetTodo(keyword: "DONE"), "(org-todo \"DONE\")"),
            ("CANCELED", SetTodo(keyword: "CANCELED"), "(org-todo \"CANCELED\")"),
            ("TODO", SetTodo(keyword: "TODO"), "(org-todo \"TODO\")"),
            ("none", SetTodo(keyword: nil), "(org-todo 'none)"),
            ("cycle", TodoCycle(), "(org-todo)"),
            ("right", TodoShift(right: true), "(org-todo 'right)"),
            ("left", TodoShift(right: false), "(org-todo 'left)"),
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, message: String?)] = []
        var labels: [String] = []
        for marked in Self.texts {
            let (text, caret) = Self.place(marked)
            let sequences = text.hasPrefix("#+TODO:")
            for (dependencies, checkboxes) in Self.settings {
                var options = EditingOptions.org
                options.enforceTodoDependencies = dependencies
                options.enforceTodoCheckboxDependencies = checkboxes
                for (name, command, form) in changes where sequences || name != "CANCELED" {
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text),
                                                  form: Self.form(form, dependencies: dependencies, checkboxes: checkboxes)))
                    ours.append(Self.run(command, text, caret: caret, options: options))
                    labels.append("\(form) dependencies \(dependencies) checkboxes \(checkboxes)")
                }
            }
        }
        for (i, theirs) in try EmacsOracle.run(cases).enumerated() {
            #expect(ours[i].text == theirs.text && (ours[i].message ?? "") == theirs.error,
                    "\(labels[i]) on \(cases[i].text.debugDescription)\nours:  \(ours[i].text.debugDescription) \(ours[i].message ?? "")\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }

    @Test(.enabled(if: oracle))
    func togglesOrderedLikeOrg() throws {
        let texts = [
            "* A¶\n",
            "* A¶\n:PROPERTIES:\n:ORDERED: t\n:END:\n",
            "* A\n:PROPERTIES:\n:X: 1\n:ORDERED: t\n:END:\nbody¶\n",
            "* A¶\n:PROPERTIES:\n:ORDERED: nil\n:END:\n",
            "* A¶\n:PROPERTIES:\n:ORDERED:\n:END:\n",
            "* A¶\nSCHEDULED: <2026-10-05 Mon>\nbody\n",
            "* A\n** TODO B¶ :x:\n** C\n",
            "* A¶",
            "text¶\n* A\n",
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, message: String?)] = []
        for marked in texts {
            let (text, caret) = Self.place(marked)
            cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text),
                                          form: Self.form("(org-toggle-ordered-property)", dependencies: false, checkboxes: false, keep: "Subtasks")))
            ours.append(Self.run(ToggleOrderedProperty(), text, caret: caret, options: .org))
        }
        // org-track-ordered-property-with-tag: t is the tag ORDERED, a string names the tag.
        let tracked = [
            "* A¶\n", "* A :x:¶\n", "* A :x:ORDERED:¶\n:PROPERTIES:\n:ORDERED: t\n:END:\n",
            "* TODO A    :seq:¶\n:PROPERTIES:\n:ORDERED: t\n:END:\n", "* A :ORDERED:¶\n",
        ]
        for (lisp, tag) in [("t", "ORDERED"), ("\"seq\"", "seq")] {
            var options = EditingOptions.org
            options.trackOrderedPropertyWithTag = tag
            for marked in tracked {
                let (text, caret) = Self.place(marked)
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text),
                                              form: Self.form("(let ((org-track-ordered-property-with-tag \(lisp))) (org-toggle-ordered-property))",
                                                              dependencies: false, checkboxes: false, keep: "Subtasks")))
                ours.append(Self.run(ToggleOrderedProperty(), text, caret: caret, options: options))
            }
        }
        for (i, theirs) in try EmacsOracle.run(cases).enumerated() {
            // Org's message also names the position it reached and the buffer.
            let before = "Before first headline"
            let message = theirs.error.hasPrefix(before) && ours[i].message?.hasPrefix(before) == true ? theirs.error : ours[i].message
            #expect(ours[i].text == theirs.text && (message ?? "") == theirs.error,
                    "on \(cases[i].text.debugDescription)\nours:  \(ours[i].text.debugDescription) \(ours[i].message ?? "")\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }

    /// `org-entry-blocked-p` on every heading, which the agenda dims.
    @Test(.enabled(if: oracle))
    func agendaBlockedLikeOrg() throws {
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for marked in Self.texts {
            let text = Self.place(marked).text
            let source = AgendaSource(path: "/tmp/oracle.org", text: text)
            for dependencies in [true, false] {
                let form = "(push (mapconcat #'identity (org-map-entries (lambda () (if (org-entry-blocked-p) \"b\" \"-\"))) \"\") msgs)"
                cases.append(EmacsOracle.Case(text: text, point: 1, form: Self.form(form, dependencies: dependencies, checkboxes: !dependencies, keep: "")))
                ours.append(source.headings.map { (dependencies ? $0.blockedByHierarchy : $0.blockedByCheckboxes) ? "b" : "-" }.joined())
            }
        }
        for (i, theirs) in try EmacsOracle.run(cases).enumerated() {
            #expect(ours[i] == theirs.error, "\(i % 2 == 0 ? "dependencies" : "checkboxes") on \(cases[i].text.debugDescription)")
        }
    }

    @Test func agendaDimsOrHidesBlockedEntries() {
        let text = "* TODO A\n** TODO B\n* TODO C\n- [ ] x\n* TODO D\n"
        let source = AgendaSource(path: "/tmp/a.org", text: text)
        func blocked(_ dependencies: Bool, _ checkboxes: Bool, _ dim: AgendaOptions.DimBlocked) -> [String] {
            var options = AgendaOptions()
            options.enforceTodoDependencies = dependencies
            options.enforceTodoCheckboxDependencies = checkboxes
            options.dimBlockedTasks = dim
            return Agenda.todoList([source], options: options).map { ($0.isBlocked ? "~" : "") + $0.text }
        }
        #expect(blocked(false, false, .dim) == ["TODO A", "TODO B", "TODO C", "TODO D"])
        #expect(blocked(true, true, .dim) == ["~TODO A", "TODO B", "~TODO C", "TODO D"])
        #expect(blocked(true, false, .dim) == ["~TODO A", "TODO B", "TODO C", "TODO D"])
        #expect(blocked(true, true, .off) == ["TODO A", "TODO B", "TODO C", "TODO D"])
        // Entries blocked by checkboxes are dimmed, never hidden.
        #expect(blocked(true, true, .invisible) == ["TODO B", "~TODO C", "TODO D"])
    }

    @Test func sourcesCanSkipTheBlockingCheck() {
        let source = AgendaSource(path: "/tmp/a.org", text: "* TODO A\n** TODO B\n", checksBlocking: false)
        var options = AgendaOptions()
        options.enforceTodoDependencies = true
        #expect(Agenda.todoList([source], options: options).allSatisfy { !$0.isBlocked })
    }

    @Test func dwimIsBlocked() {
        let text = "* TODO A\n** TODO B\n"
        var options = EditingOptions.org
        options.enforceTodoDependencies = true
        #expect(Self.run(OrgDwim(), text, caret: 3, options: options) == (text, "TODO state change from TODO to DONE blocked (by \"TODO B\")"))
        #expect(Self.run(OrgDwim(), text, caret: 3, options: .org).text == "* DONE A\n** TODO B\n")
    }
}
