import Foundation
import Testing
@testable import OrgCore

struct ListCommandTests {
    @Test func basics() {
        #expect(runCommand(InsertItem(), "- a\n", caret: 3).text == "- a\n- \n")
        #expect(runCommand(InsertItem(), "1. a\n2. b\n", caret: 4).text == "1. a\n2. \n3. b\n")
        #expect(runCommand(IndentItem(), "- a\n- b\n", caret: 4).text == "- a\n  - b\n")
        #expect(runCommand(OutdentItem(), "- a\n  - b\n", caret: 6).text == "- a\n- b\n")
        #expect(runCommand(MoveItemDown(), "- a\n- b\n", caret: 0).text == "- b\n- a\n")
        #expect(runCommand(ToggleCheckbox(), "* h [0/1]\n- [ ] a\n", caret: 12).text == "* h [1/1]\n- [X] a\n")
        #expect(runCommand(IndentItem(), "text\n", caret: 0).failure != nil)
    }
}

struct ListOracleTests {
    static let variants = [
        "- a\n- b\n- c\n",
        "1. one\n2. two\n3. three\n",
        "- a\n  - b\n  - c\n- d\n",
        "- [ ] a\n- [X] b\n",
        "* T [1/3]\n- [X] a\n- [ ] b\n- [ ] c\n",
        "* T [50%]\n- [ ] a\n  - [X] b\n  - [ ] c\n",
        "- a\n\n- b\n",
        "- term :: def\n- other :: x\n",
        "text\n- a\n  more\n- b\nafter\n",
        "1) x\n2) y\n",
        "- a 😀\n  - b\n",
        "#+begin_src\n- a\n#+end_src\n",
        "- a\n- b\n        - c\n- d\n",
    ]

    static let commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)] = [
        (InsertItem(), "(or (org-insert-item) (error \"Not in an item\"))", false),
        (InsertCheckboxItem(), "(or (org-insert-item 'checkbox) (error \"Not in an item\"))", false),
        (IndentItem(), "(org-indent-item)", false),
        (OutdentItem(), "(org-outdent-item)", false),
        (IndentItemTree(), "(org-indent-item-tree)", false),
        (OutdentItemTree(), "(org-outdent-item-tree)", false),
        (MoveItemUp(), "(org-move-item-up)", false),
        (MoveItemDown(), "(org-move-item-down)", false),
        (ToggleCheckbox(), "(if (org-at-heading-p) (error \"heading\") (org-toggle-checkbox))", false),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func listCommandsMatchEmacs() throws {
        try compareWithEmacs(Self.variants.map { ($0, EmacsOracle.positions($0)) }, Self.commands)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func listCommandsMatchEmacsWithDoomOptions() throws {
        let alphabetical = ["a. x\nb. y\n", "A) one\n   - sub\nB) two\n", "- [@c] x\n- y\n", "1. a\n2. b\n"]
        try compareWithEmacs((Self.variants + alphabetical).map { ($0, EmacsOracle.positions($0)) }, Self.commands, options: doomOptions)
    }

    /// Real lists: `ORGSTAR_ORACLE_CORPUS=<folder>` runs every list command in files up to
    /// 20 KB with the caret at the start, bullet end and end of up to six item lines per file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func listCommandsMatchEmacsOnACorpus() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "org" }.sorted { $0.path < $1.path }
        let item = try NSRegularExpression(pattern: "^[ \\t]*(?:[-+]|[0-9]+[.)]) ")
        var samples: [(String, [Int])] = []
        for file in files where samples.count < 60 {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf16.count <= 20_000, !text.contains("\r") else { continue }
            let ns = text as NSString
            var carets: [Int] = []
            var location = 0
            while location < ns.length, carets.count < 18 {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                if let match = item.firstMatch(in: text, options: .anchored, range: line) {
                    carets += [line.location, NSMaxRange(match.range), NSMaxRange(line) - (ns.substring(with: line).hasSuffix("\n") ? 1 : 0)]
                }
                location = NSMaxRange(line)
            }
            if !carets.isEmpty { samples.append((text, carets)) }
        }
        try compareWithEmacs(samples, Self.commands)
    }
}

/// Checkbox lists with `#+ATTR_ORG: :radio t`: one box checked at a time.
struct RadioListOracleTests {
    static let variants = [
        "#+ATTR_ORG: :radio t\n- [ ] a\n- [X] b\n- [ ] c\n",
        "#+attr_org: :radio t\n- a\n- [ ] b\n",
        "#+ATTR_ORG: :radio nil\n- [ ] a\n- [X] b\n",
        "#+NAME: pick\n#+ATTR_ORG: :width 10 :radio yes\n#+CAPTION: c\n- [X] a\n- [ ] b\n",
        "* T [1/3]\n#+ATTR_ORG: :radio t\n- [ ] a\n- [X] b\n- [ ] c\n",
        "#+ATTR_ORG: :radio t\n- [ ] a\n  - [ ] x\n  - [X] y\n- [X] b\n",
        "#+ATTR_ORG: :radio t\n#+TITLE: t\n- [ ] a\n- [X] b\n",
        "#+ATTR_ORG: :radio t\n\n- [ ] a\n- [X] b\n",
        "#+ATTR_ORG: :radio t\n1. [ ] one\n2. [ ] two\n",
    ]

    static let commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)] = [
        (ToggleCheckbox(), "(if (org-at-heading-p) (error \"heading\") (org-toggle-checkbox))", false),
        (CtrlCCtrlC(), "(org-ctrl-c-ctrl-c)", false),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func radioButtonsMatchEmacs() throws {
        // Off heading lines, where C-c C-c asks for tags.
        try compareWithEmacs(Self.variants.map { text in
            (text, EmacsOracle.positions(text).filter { headingOnLine(at: $0, in: OrgParser.parse(text)) == nil })
        }, Self.commands)
    }
}
