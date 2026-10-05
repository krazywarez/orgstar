import Foundation
import Testing
@testable import OrgCore

struct PropertyTests {
    static let texts = [
        "* TODO Task\n",
        "* TODO Task\nBody\n",
        "* Task\nSCHEDULED: <2026-10-05 Mon>\nBody\n",
        "* Task\n:PROPERTIES:\n:OWNER: alice\n:SIZE:     3\n:END:\nBody\n",
        "* Task :tag:\n:PROPERTIES:\n:ID: x\n:END:\n** Child\n",
        "* DONE Old\n* TODO Repeat\nSCHEDULED: <2026-10-05 Mon +1w>\n",
        "* Task",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let edits: [(any OrgCommand, String)] = [
            (SetProperty(key: "OWNER", value: "bob"), "(org-entry-put nil \"OWNER\" \"bob\")"),
            (SetProperty(key: "Effort", value: "1:30"), "(org-entry-put nil \"Effort\" \"1:30\")"),
            (SetProperty(key: "LONGPROPERTYNAME", value: "v"), "(org-entry-put nil \"LONGPROPERTYNAME\" \"v\")"),
            (SetProperty(key: "SIZE", value: ""), "(org-entry-put nil \"SIZE\" \"\")"),
            (SetTodo(keyword: "DONE"), "(org-todo \"DONE\")"),
            (SetTodo(keyword: "TODO"), "(org-todo \"TODO\")"),
            (SetTodo(keyword: nil), "(org-todo 'none)"),
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [(text: String, caret: Int, failure: String?)] = []
        for text in Self.texts {
            for heading in [(text as NSString).range(of: "Task").location, (text as NSString).range(of: "Repeat").location] where heading != NSNotFound {
                for (command, form) in edits {
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(heading, in: text), form: frozenClock(1_789_000_000, "(progn \(form) (run-hooks 'post-command-hook))")))
                    var utc = Calendar(identifier: .gregorian)
                    utc.timeZone = TimeZone(identifier: "UTC")!
                    let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [heading..<heading], now: Date(timeIntervalSince1970: 1_789_000_000), calendar: utc)
                    switch command.run(in: context) {
                    case .commit(let result):
                        var new = text
                        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
                        ours.append((new, heading, nil))
                    case .failed(let message): ours.append((text, heading, message))
                    default: ours.append((text, heading, "other"))
                    }
                }
            }
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text, "\(cases[i].form.split(separator: "\n").last ?? "") on \(cases[i].text.debugDescription)\nours:  \(mine.text.debugDescription) \(mine.failure ?? "")\nemacs: \(theirs.text.debugDescription) \(theirs.error)")
        }
    }
}

struct BoardTests {
    @Test func entriesAndKeywords() {
        let source = AgendaSource(path: "/n/a.org", text: """
        #+TODO: TODO NEXT | DONE
        * TODO [#A] One :work:
        :PROPERTIES:
        :EFFORT: 1:00
        :END:
        * Plain
        * DONE Two
        DEADLINE: <2026-10-05 Mon>
        * ARCHIVED TODO :ARCHIVE:
        ** TODO Hidden
        """)
        let all = Board.entries([source], match: "")
        #expect(all.map(\.title) == ["One", "Two"])
        #expect(all[0].properties["EFFORT"] == "1:00" && all[0].priority == "A" && all[0].tags == ["work"])
        #expect(all[1].deadline == "2026-10-05 Mon")
        #expect(Board.entries([source], match: "+work").map(\.title) == ["One"])
        #expect(Board.keywords([source]) == ["TODO", "NEXT", "DONE"])
    }
}
