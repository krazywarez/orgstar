import Foundation
import Testing
@testable import OrgCore

struct StructureCommandTests {
    @Test func insertHeading() {
        #expect(runCommand(InsertHeading(), "* a\nbody\n", caret: 3).text == "* a\n* \nbody\n")
        #expect(runCommand(InsertHeading(), "* ab\n", caret: 3).text == "* a\n* b\n")
        #expect(runCommand(InsertHeadingAfterSubtree(), "* a\nbody\n** b\n* c\n", caret: 1).text == "* a\nbody\n** b\n* \n* c\n")
        #expect(runCommand(InsertTodoHeading(), "* TODO a\n", caret: 8).text == "* TODO a\n* TODO \n")
    }

    @Test func moveAndLevels() {
        #expect(runCommand(MoveSubtreeDown(), "* a\nx\n* b\ny\n", caret: 0).text == "* b\ny\n* a\nx\n")
        #expect(runCommand(MoveSubtreeUp(), "* a\n* b\n", caret: 0).failure != nil)
        #expect(runCommand(DemoteSubtree(), "* a\n** b\n* c\n", caret: 0).text == "** a\n*** b\n* c\n")
        #expect(runCommand(PromoteSubtree(), "* a\n", caret: 0).failure != nil)
    }

    @Test func motion() {
        let text = "intro\n* a\n** b\n** c\n* d\n"
        #expect(runCommand(NextHeading(), text, caret: 0).caret == 6)
        #expect(runCommand(ForwardSameLevel(), text, caret: 10).caret == 15)
        #expect(runCommand(BackwardSameLevel(), text, caret: 16).caret == 10)
        #expect(runCommand(UpHeading(), text, caret: 16).caret == 6)
        #expect(runCommand(UpHeading(), text, caret: 6).failure != nil)
    }

    @Test func nextHeadingSkipsHiddenOnes() {
        let text = "* a\n** b\n* c\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [0..<0], hidden: [3..<8])
        guard case .commit(let result) = NextHeading().run(in: context) else {
            Issue.record("expected a commit")
            return
        }
        #expect(result.selection == [9..<9])
    }

    /// The caret at the end of a folded heading stands for Emacs's point behind the ellipsis:
    /// the new heading goes after the subtree, not between the heading and its folded body.
    @Test func newHeadingAtTheEndOfAFoldedHeadingGoesAfterTheSubtree() {
        let text = "* One\nbody one\n** One child\nchild body\n* Two\nbody two\n"
        // As the editors hide a folded heading: the lines after it, to its section's end.
        let fold = 6..<(text as NSString).range(of: "* Two").location
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [5..<5], hidden: [fold])
        guard case .commit(let result) = InsertHeading().run(in: context) else {
            Issue.record("expected a commit")
            return
        }
        let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
        #expect(new == "* One\nbody one\n** One child\nchild body\n* \n* Two\nbody two\n")
    }
}

struct StructureOracleTests {
    static let variants = [
        "* a\nbody\n* b\nmore\n",
        "* a\n\n* b\n\n* c\n",
        "intro\n* a\n** b\ntext\n** c\n* d\n",
        "* TODO a :x:\n** DONE b\n* c :y:\n",
        "* a\n** b\n*** c\n** d\n",
        "* a\n* b",
        "text\nmore\n",
        "\n* a\n\nbody\n\n* b\n",
        "* TODO [#A] title here :t:\nbody\n",
        "* a 😀 b\n** c\n",
        "* P [0/1]\n** TODO a\n",
    ]

    static let commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)] = [
        (InsertHeading(), "(org-insert-heading)", false),
        (InsertHeadingAfterSubtree(), "(org-insert-heading-respect-content)", false),
        (InsertTodoHeading(), "(org-insert-todo-heading nil)", false),
        (MoveSubtreeUp(), "(org-move-subtree-up)", false),
        (MoveSubtreeDown(), "(org-move-subtree-down)", false),
        (PromoteSubtree(), "(org-promote-subtree)", false),
        (DemoteSubtree(), "(org-demote-subtree)", false),
        (NextHeading(), "(org-next-visible-heading 1)", false),
        (PreviousHeading(), "(org-previous-visible-heading 1)", false),
        (ForwardSameLevel(), "(org-forward-heading-same-level 1)", false),
        (BackwardSameLevel(), "(org-backward-heading-same-level 1)", false),
        (UpHeading(), "(outline-up-heading 1)", false),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func structureCommandsMatchEmacs() throws {
        try compareWithEmacs(Self.variants.map { ($0, EmacsOracle.positions($0)) }, Self.commands)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func structureCommandsMatchEmacsWithDoomOptions() throws {
        try compareWithEmacs(Self.variants.map { ($0, EmacsOracle.positions($0)) }, Self.commands, options: doomOptions)
    }

    /// Real files: `ORGSTAR_ORACLE_CORPUS=<folder>` runs every structure command in files up to
    /// 20 KB, with the caret at the start and end of up to eight heading lines per file and on
    /// a body line, for up to 60 files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func structureCommandsMatchEmacsOnACorpus() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "org" }.sorted { $0.path < $1.path }
        var samples: [(String, [Int])] = []
        for file in files where samples.count < 60 {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf16.count <= 20_000, !text.contains("\r") else { continue }
            let ns = text as NSString
            var carets: [Int] = []
            var location = 0
            while location < ns.length, carets.count < 17 {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                let content = ns.substring(with: line)
                if content.hasPrefix("* ") || content.hasPrefix("** ") || content.hasPrefix("*** ") {
                    carets.append(line.location)
                    carets.append(NSMaxRange(line) - (content.hasSuffix("\n") ? 1 : 0))
                } else if carets.count == 2 {
                    carets.append(line.location)
                }
                location = NSMaxRange(line)
            }
            if !carets.isEmpty { samples.append((text, carets)) }
        }
        try compareWithEmacs(samples, Self.commands)
    }
}
