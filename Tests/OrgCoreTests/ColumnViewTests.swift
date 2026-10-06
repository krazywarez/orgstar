import Foundation
import Testing
@testable import OrgCore

struct ColumnViewTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    static let text = """
        #+COLUMNS: %25ITEM %TODO %3PRIORITY %Effort{:} %Cost{+;%.1f} %Done{X/} %TAGS
        * Project :work:
        :PROPERTIES:
        :Effort:   9:00
        :END:
        ** TODO [#A] Design <<target>> [1/2]
        :PROPERTIES:
        :Effort:   2:30
        :Cost:     10
        :Done:     [X]
        :END:
        ** DONE Build | it
        DEADLINE: <2026-10-01 Thu> SCHEDULED: <2026-09-20 Sun>
        :PROPERTIES:
        :Effort:   1d
        :Cost:     2.5
        :Done:     [ ]
        :END:
        *** Sub task :home:
        :PROPERTIES:
        :Effort:   0:45
        :END:
        ** Archived :ARCHIVE:
        :PROPERTIES:
        :Effort:   5:00
        :END:
        * COMMENT Hidden
        * Other
        :PROPERTIES:
        :COLUMNS:  %ITEM(Task) %SCHEDULED %DEADLINE %ALLTAGS %Cost{max} %Cost{mean}
        :END:
        ** One thing
        :PROPERTIES:
        :Cost:     4
        :END:
        ** Two things
        SCHEDULED: <2026-11-01 Sun 10:00>
        :PROPERTIES:
        :Cost:     7
        :END:
        """ + "\n"

    @Test(.enabled(if: oracle))
    func writesColumnViewBlocksLikeOrg() throws {
        let blocks = [
            ("Project", "#+BEGIN: columnview :hlines 1 :id local\n#+END:\n"),
            ("Other", "#+BEGIN: columnview :hlines 1 :id local\n#+END:\n"),
            ("Project", "#+BEGIN: columnview :id global :indent t :hlines t\n#+END:\n"),
            ("Project", "#+BEGIN: columnview :id local :maxlevel 2 :skip-empty-rows t :exclude-tags (\"home\")\n#+END:\n"),
            ("Project", "#+BEGIN: columnview :id local :format \"%ITEM %Effort{:max} %Effort{:mean} %Cost{$}\"\n| x |\n#+TBLFM: $4=$4*2\n#+END:\n"),
        ]
        var cases: [EmacsOracle.Case] = []
        var texts: [String] = []
        for (heading, block) in blocks {
            // The block goes under the heading's drawer.
            let ns = Self.text as NSString
            let start = ns.range(of: "* " + heading).location
            let drawerEnd = ns.range(of: ":END:\n", range: NSRange(location: start, length: ns.length - start))
            let at = NSMaxRange(drawerEnd)
            let text = ns.replacingCharacters(in: NSRange(location: at, length: 0), with: block)
            texts.append(text)
            cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(at, in: text), form: "(org-update-dblock)"))
        }
        let emacs = try EmacsOracle.run(cases)
        for (i, text) in texts.enumerated() {
            let at = Int(cases[i].point) - 1
            let ours = runCommand(UpdateDynamicBlock(), text, caret: EmacsOracle.offset(at + 1, in: text))
            #expect(ours.text == emacs[i].text, "\(blocks[i].1)\nours:\n\(ours.text)\n\(ours.failure ?? "")\nemacs:\n\(emacs[i].text)\n\(emacs[i].error)")
        }
    }

    @Test func compilesFormats() {
        let specs = ColumnView.compile("%25ITEM(Task) %Effort{:} %3PRIORITY %Cost{+;%.2f}")
        #expect(specs.map(\.property) == ["ITEM", "EFFORT", "PRIORITY", "COST"])
        #expect(specs[0].title == "Task" && specs[0].width == 25)
        #expect(specs[3].summary == "+" && specs[3].format == "%.2f")
    }
}
