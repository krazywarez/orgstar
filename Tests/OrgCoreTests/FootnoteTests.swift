import Foundation
import Testing
@testable import OrgCore

struct FootnoteTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let messy = """
        #+TITLE: Notes
        * H
        A[fn:b] B[fn:2] C[fn::anon text] D[fn:x:inline def].

        [fn:2] Two.
        Still two.

        [fn:b] Bee[fn:n].

        [fn:z] Unused.

        [fn:n] Nested.
        * Other
        E[fn:2] and *bold* text
        """ + "\n"

    /// (text, where the caret goes: the offset of this marker's end, or its start with a "^"
    /// prefix, in the text).
    static func caret(_ text: String, _ at: String) -> Int {
        let start = at.hasPrefix("^")
        let needle = start ? String(at.dropFirst()) : at
        let r = (text as NSString).range(of: needle)
        precondition(r.location != NSNotFound, needle)
        return start ? r.location : NSMaxRange(r)
    }

    func compare(_ cases: [(text: String, at: String, command: any OrgCommand, answers: [String: String], form: String)]) throws {
        let emacs = try EmacsOracle.run(cases.map { c in
            EmacsOracle.Case(text: c.text, point: EmacsOracle.point(Self.caret(c.text, c.at), in: c.text), form: c.form)
        })
        for (c, theirs) in zip(cases, emacs) {
            let ours = runCommand(c.command, c.text, caret: Self.caret(c.text, c.at), answers: c.answers)
            let theirCaret = EmacsOracle.offset(theirs.point, in: theirs.text)
            #expect(ours.text == theirs.text && ours.failure == nil && ours.caret == theirCaret && theirs.error.isEmpty,
                    "\(c.form) at \(c.at.debugDescription)\nours:  \(ours.text.debugDescription) @\(ours.caret) \(ours.failure ?? "")\nemacs: \(theirs.text.debugDescription) @\(theirCaret) \(theirs.error)")
        }
    }

    static func menu(_ key: Character) -> String {
        "(cl-letf (((symbol-function 'read-char-exclusive) (lambda (&rest _) ?\(key)))) (org-footnote-action '(4)))"
    }

    @Test(.enabled(if: oracle))
    func actsLikeOrgFootnoteAction() throws {
        let action = "(cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (org-footnote-action))"
        let plain = "* H\nSome text here.\n"
        let sectioned = "* H\nText[fn:1] more.\n\n* Footnotes\n\n[fn:1] One.\n"
        let tagged = "* TODO Heading title :tag:\nBody\n"
        let missing = "* H\nSee[fn:q] here.\n* Next\n"
        try compare([
            (plain, "Some text", FootnoteAction(), [:], action),
            (plain, "here.", FootnoteAction(), [:], action),
            ("Top text\n", "Top", FootnoteAction(), [:], action),
            (sectioned, "more", FootnoteAction(), [:], action),
            (sectioned, "Text[fn", FootnoteAction(), [:], action),
            (sectioned, "^[fn:1] One", FootnoteAction(), [:], action),
            (sectioned, "[fn:1] O", FootnoteAction(), [:], action),
            (tagged, "Heading", FootnoteAction(), [:], action),
            (Self.messy, "B[fn:", FootnoteAction(), [:], action),
            (Self.messy, "C[fn::an", FootnoteAction(), [:], action),
            (Self.messy, "D[fn:x:in", FootnoteAction(), [:], action),
            (Self.messy, "^[fn:b] Bee", FootnoteAction(), [:], action),
            (Self.messy, "Still", FootnoteAction(), [:], action),
            (Self.messy, "E[fn:2] and *bo", FootnoteAction(), [:], action),
            (missing, "See[fn", FootnoteAction(), ["create": "yes"], action),
        ])
    }

    @Test(.enabled(if: oracle))
    func runsTheFootnoteMenuLikeOrg() throws {
        let text = Self.messy
        var cases: [(text: String, at: String, command: any OrgCommand, answers: [String: String], form: String)] = []
        for key in ["s", "r", "S", "n"] {
            cases.append((text, "Notes", FootnoteAction(special: true), ["footnote": key], Self.menu(Character(key))))
        }
        cases.append((text, "B[fn:", FootnoteAction(special: true), ["footnote": "d"], Self.menu("d")))
        cases.append((text, "C[fn::an", FootnoteAction(special: true), ["footnote": "d"], Self.menu("d")))
        cases.append((text, "Unused", FootnoteAction(special: true), ["footnote": "d"], Self.menu("d")))
        let numbered = "* H\nX[fn:3] Y[fn:1] Z[fn:3]\n\n[fn:1] one\n\n[fn:3] three\n\n[fn:7] seven\n"
        cases.append((numbered, "^X", FootnoteAction(special: true), ["footnote": "r"], Self.menu("r")))
        cases.append((numbered, "^X", FootnoteAction(special: true), ["footnote": "S"], Self.menu("S")))
        cases.append((numbered, "^X", FootnoteAction(special: true), ["footnote": "n"], Self.menu("n")))
        try compare(cases)
    }

    @Test func offersTheMenuWhereNoReferenceCanGo() {
        let text = "#+TITLE: Notes\n| a | b |\n"
        #expect(runCommand(FootnoteAction(), text, caret: 5).failure == "prompt: footnote")
        #expect(runCommand(CtrlCCtrlC(), "A[fn:1]\n\n[fn:1] x\n", caret: 2).caret == 15)
    }
}
