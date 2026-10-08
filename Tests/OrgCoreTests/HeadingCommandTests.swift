import Foundation
import Testing
@testable import OrgCore

struct HeadingCommandTests {
    @Test func todoCycle() {
        let cycle = TodoCycle()
        #expect(runCommand(cycle, "* a\n", caret: 2).text == "* TODO a\n")
        #expect(runCommand(cycle, "* TODO a\n", caret: 2).text == "* DONE a\n")
        #expect(runCommand(cycle, "* DONE a\n", caret: 2).text == "* a\n")
        #expect(runCommand(cycle, "* TODO\n", caret: 2).text == "* DONE \n")
        #expect(runCommand(cycle, "#+TODO: A B | C\n* B x\n", caret: 18).text == "#+TODO: A B | C\n* C x\n")
        #expect(runCommand(cycle, "text\n", caret: 1).failure != nil)
    }

    /// `#+TYP_TODO`: a first C-c C-t goes to the done keyword, a repeated one to the next type.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func typeKeywordsMatchEmacs() throws {
        let texts = [
            "#+TYP_TODO: Fred Sara Lucy | DONE\n* Fred a\n", "#+TYP_TODO: Fred Sara Lucy | DONE\n* Sara a\n",
            "#+TYP_TODO: Fred Sara Lucy | DONE\n* Lucy a\n", "#+TYP_TODO: Fred Sara Lucy | DONE\n* DONE a\n",
            "#+TYP_TODO: Fred Sara | DONE GONE\n* Sara a\n", "#+TYP_TODO: Fred Sara | DONE GONE\n* DONE a\n",
            "#+TYP_TODO: Fred Sara | DONE\n* a\n", "#+TODO: TODO | DONE\n#+TYP_TODO: Fred Sara | OK\n* Fred a\n",
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for text in texts {
            let caret = (text as NSString).range(of: "\n*").location + 2
            for repeated in [false, true] {
                let last = repeated ? "'org-todo" : "'other"
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: "(let ((this-command 'org-todo) (last-command \(last))) (org-todo))"))
                let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], lastCommand: repeated ? TodoCycle().id : "org.other")
                guard case .commit(let result) = TodoCycle().run(in: context) else { ours.append("failed"); continue }
                ours.append(result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) })
            }
        }
        let emacs = try EmacsOracle.run(cases)
        #expect(emacs.count == ours.count)
        for (mine, emacs) in zip(ours, emacs) {
            #expect(mine == emacs.text)
        }
        #expect(ours[0].hasSuffix("* DONE a\n") && ours[1].hasSuffix("* Sara a\n"))
    }

    @Test func caretMovesToTheTitleWhenBeforeIt() {
        #expect(runCommand(TodoCycle(), "* a\n", caret: 2).caret == 7)
        #expect(runCommand(TodoCycle(), "* TODO abc\nbody\n", caret: 13).caret == 13)
    }

    @Test func priorities() {
        #expect(runCommand(PriorityUp(), "* a\n", caret: 2).text == "* [#B] a\n")
        #expect(runCommand(PriorityUp(), "* [#A] a\n", caret: 2).text == "* a\n")
        #expect(runCommand(PriorityDown(), "* TODO a\n", caret: 2).text == "* TODO [#B] a\n")
        #expect(runCommand(PriorityDown(), "* [#C] a\n", caret: 2).text == "* a\n")
    }

    @Test func promoteAndDemote() {
        #expect(runCommand(DemoteHeading(), "* a\nbody\n", caret: 2).text == "** a\nbody\n")
        #expect(runCommand(PromoteHeading(), "** a\n", caret: 3).text == "* a\n")
        #expect(runCommand(PromoteHeading(), "* a\n", caret: 0).failure != nil)
        #expect(runCommand(DemoteHeading(), "* a\nbody\n", caret: 6).failure != nil)
    }

    @Test func tagsAlignToColumn77() {
        let result = runCommand(PriorityUp(), "* TODO a :t:\n", caret: 2).text
        #expect(result == "* TODO [#B] a" + String(repeating: " ", count: 77 - 13 - 3) + ":t:\n")
    }
}

/// Every heading variant, every caret position, every heading command, against Emacs.
/// Fails when Emacs is missing unless `ORGSTAR_SKIP_ORACLE` is set.
struct HeadingOracleTests {
    static let variants = [
        "* a\nbody\n", "* TODO a\n", "* DONE a\n", "** [#B] two words :tag:\n", "* TODO [#A] x :a:b:\nbody\n",
        "* \n", "* TODO\n", "*** title with 日本 :t:\n", "* a😀 b\n", "* a  :t:\n", "text\n* a\n", "*  a\n",
        "* TODO  a\n", "* a\r\n",
        "#+TODO: NEXT WAIT | DONE CANCELED\n* WAIT a :t:\n",
        "* " + String(repeating: "long ", count: 16) + "title :t:\n",
        "* TODO\ttab\n",
        "* P [1/2]\n** TODO a\n** DONE b\n",
        "* P [50%] :t:\n** TODO a\n*** TODO deep\n** b\n",
    ]

    /// Commands, their Emacs forms, and whether they only act on heading lines.
    static let commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)] = [
        (TodoCycle(), "(org-todo)", false),
        (PriorityUp(), "(org-priority-up)", true),
        (PriorityDown(), "(org-priority-down)", true),
        (PromoteHeading(), "(org-do-promote)", true),
        (DemoteHeading(), "(org-do-demote)", true),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func headingCommandsMatchEmacs() throws {
        try compareWithEmacs(Self.variants.map { ($0, EmacsOracle.positions($0)) }, Self.commands)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func headingCommandsMatchEmacsWithDoomOptions() throws {
        try compareWithEmacs(Self.variants.map { ($0, EmacsOracle.positions($0)) }, Self.commands, options: doomOptions)
    }

    /// Real headings: `ORGSTAR_ORACLE_CORPUS=<folder>` runs every command on up to 400 heading
    /// lines from the folder's files, with the caret at the line start, the title start and
    /// the line end.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func headingCommandsMatchEmacsOnACorpus() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        var samples: [(String, [Int])] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "org" }.sorted { $0.path < $1.path }
        for file in files where samples.count < 400 {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var settings = ""
            for line in text.components(separatedBy: "\n") where line.uppercased().hasPrefix("#+TODO:") || line.uppercased().hasPrefix("#+SEQ_TODO:") {
                settings += line + "\n"
            }
            for line in text.components(separatedBy: "\n") where line.hasPrefix("*") && samples.count < 400 {
                let sample = settings + line + "\n"
                guard let heading = entryHeading(at: (sample as NSString).length - 1, in: OrgParser.parse(sample)) else { continue }
                let parts = HeadingLine(heading)
                samples.append((sample, [parts.start, parts.titleStart, parts.contentEnd]))
            }
        }
        try compareWithEmacs(samples, Self.commands)
    }
}

/// Runs every command at every caret of every input here and in Emacs, and records each
/// difference in text, caret or failure.
func compareWithEmacs(_ inputs: [(text: String, carets: [Int])], _ commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)], options: EditingOptions = .org) throws {
    try #require(EmacsOracle.isAvailable, "Emacs is required for the oracle tests; set ORGSTAR_SKIP_ORACLE to skip")
    var cases: [EmacsOracle.Case] = []
    var ours: [(label: String, text: String, caret: Int, failed: Bool)] = []
    for (text, carets) in inputs {
        for offset in carets {
            let onHeadingLine = headingOnLine(at: offset, in: OrgParser.parse(text)) != nil
            for (command, form, headingLineOnly) in commands where onHeadingLine || !headingLineOnly {
                cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(offset, in: text), form: withOptions(options, form)))
                let result = runCommand(command, text, caret: offset, options: options)
                ours.append(("\(command.id) at \(offset) in \(text.debugDescription)", result.text, result.caret, result.failure != nil))
            }
        }
    }
    let theirs = try EmacsOracle.run(cases)
    var mismatches = 0
    for (mine, emacs) in zip(ours, theirs) {
        let emacsFailed = !emacs.error.isEmpty
        let emacsCaret = EmacsOracle.offset(emacs.point, in: emacs.text)
        let same = mine.failed == emacsFailed && (emacsFailed || (mine.text == emacs.text && mine.caret == emacsCaret))
        if !same {
            mismatches += 1
            if mismatches <= 15 {
                let (a, b) = excerpts(mine.text, emacs.text)
                Issue.record("""
                    \(mine.label.prefix(100))
                      ours:  \(mine.failed ? "failed" : "\(a.debugDescription) @\(mine.caret)")
                      emacs: \(emacsFailed ? "failed: \(emacs.error)" : "\(b.debugDescription) @\(emacsCaret)")
                    """)
            }
        }
    }
    #expect(mismatches == 0, "\(mismatches) of \(ours.count) cases differ from Emacs")
}

/// The parts of two texts around their first difference.
func excerpts(_ a: String, _ b: String) -> (String, String) {
    let x = Array(a.utf16), y = Array(b.utf16)
    var prefix = 0
    while prefix < min(x.count, y.count), x[prefix] == y[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(x.count, y.count) - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
    let start = max(0, prefix - 40)
    func cut(_ s: [UInt16]) -> String {
        let end = min(s.count, s.count - suffix + 40)
        return "…" + String(decoding: s[start..<max(start, end)], as: UTF16.self) + "…"
    }
    return (cut(x), cut(y))
}
