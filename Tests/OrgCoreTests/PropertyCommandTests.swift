import Foundation
import Testing
@testable import OrgCore

struct PropertyCommandTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        #+PROPERTY: Color_ALL red green "dark blue" :ETC
        * Parent
        :PROPERTIES:
        :Size_ALL: S M L 010
        :Size:     M
        :END:
        ** Child
        :PROPERTIES:
        :Size:     L
        :Color:    green
        :Done:     [ ]
        :END:
        body
        ** Bare
        SCHEDULED: <2026-10-05 Mon>
        * Other
        :PROPERTIES:
        :Size:     S
        :END:
        """ + "\n"

    func compare(_ cases: [(at: String, command: any OrgCommand, answers: [String: String], form: String)]) throws {
        let ns = Self.text as NSString
        let emacs = try EmacsOracle.run(cases.map { c in
            EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(ns.range(of: c.at).location, in: Self.text), form: c.form)
        })
        for (c, theirs) in zip(cases, emacs) {
            let ours = runCommand(c.command, Self.text, caret: ns.range(of: c.at).location, answers: c.answers)
            #expect(ours.text == theirs.text, "\(c.form) at \(c.at)\nours:  \(ours.text.debugDescription) \(ours.failure ?? "")\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
            #expect((ours.failure != nil) == !theirs.error.isEmpty, "\(c.form): \(ours.failure ?? "") vs \(theirs.error)")
        }
    }

    @Test(.enabled(if: oracle))
    func setsAndDeletesLikeOrg() throws {
        try compare([
            ("Child", ReadAndSetProperty(), ["property": "Color", "value": "red"], "(org-set-property \"Color\" \"red\")"),
            ("Bare", ReadAndSetProperty(), ["property": "Size", "value": "S"], "(org-set-property \"Size\" \"S\")"),
            ("Other", ReadAndSetProperty(), ["property": "Size", "value": "S"], "(org-set-property \"Size\" \"S\")"),
            ("Child", DeleteProperty(), ["property": "Color"], "(org-delete-property \"Color\")"),
            ("Other", DeleteProperty(), [:], "(org-delete-property \"Size\")"),
            ("Parent", DeleteProperty(globally: true), ["property": "Size"], "(org-delete-property-globally \"Size\")"),
            (":Size:     L", NextAllowedValue(previous: false), [:], "(org-property-next-allowed-value)"),
            (":Size:     L", NextAllowedValue(previous: true), [:], "(org-property-next-allowed-value t)"),
            (":Size:     M", NextAllowedValue(previous: false), [:], "(org-property-next-allowed-value)"),
            (":Color:    green", NextAllowedValue(previous: false), [:], "(org-property-next-allowed-value)"),
            (":Done:", NextAllowedValue(previous: false), [:], "(org-property-next-allowed-value)"),
            (":Size:     S", NextAllowedValue(previous: false), [:], "(org-property-next-allowed-value)"),
        ])
    }

    @Test(.enabled(if: oracle))
    func findsAllowedValuesLikeOrg() throws {
        let ns = Self.text as NSString
        let spots = [("Child", "Size"), ("Child", "Color"), ("Other", "Size"), ("Child", "TODO"), ("Child", "PRIORITY"), ("Bare", "Shape")]
        let forms = spots.map { at, key in
            "(progn (goto-char \(EmacsOracle.point(ns.range(of: at).location, in: Self.text))) (mapconcat #'identity (org-property-get-allowed-values (point) \(lispString(key))) \"|\"))"
        }
        let emacs = try EmacsOracle.evaluate(Self.text, "(with-current-buffer (find-file-noselect \"oracle.org\") (list \(forms.joined(separator: " "))))")
        let tree = OrgParser.parse(Self.text)
        let ours = spots.map { at, key in PropertyValues.allowed(key, at: ns.range(of: at).location, text: Self.text, tree: tree)?.values.joined(separator: "|") ?? "" }
        #expect(ours == emacs)
    }
}
