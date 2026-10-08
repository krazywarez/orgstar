import Foundation
import Testing
@testable import OrgCore

struct FillTests {
    @Test func fillsAParagraph() {
        let text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen\n"
        let filled = runCommand(FillParagraph(), text, caret: 0).text
        #expect(filled == "one two three four five six seven eight nine ten eleven twelve\nthirteen fourteen fifteen\n")
    }

    static let long = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris."
    static let variants = [
        long + "\n",
        "Short\nlines that\nshould join.  Two spaces after.\n",
        "- item " + long + "\n  - nested " + long + "\n",
        "1. [ ] " + long + "\n",
        "# comment " + long + "\n# more\n",
        "* Heading\n" + long + "\n\nSecond " + long + "\n",
        "  indented " + long + "\n  continued\n",
        "> quoted " + long + "\n> more quoted text\n",
        "Has a line break \\\\\n" + long + "\n",
        "Date <2026-09-10 Thu 10:00> inside a long sentence that keeps going and going and going past the column.\n",
        "A [[https://example.com/a/very/long/path][link with a description]] that runs past the fill column for sure.\n",
        "Ends with - a dash that would start a list if it began a line and continues further on.\n",
        "Words  with   extra    spaces\tand\ttabs that should collapse into single spaces when filled together.\n",
        "#+CAPTION: cap\nCaptioned paragraph " + long + "\n",
        "*bold start* of a line with " + long + "\n",
        "Unicode ünïcödé wörds ñ " + long + "\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func fillMatchesEmacs() throws {
        let commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)] = [(FillParagraph(), "(org-fill-paragraph)", false)]
        let inputs = Self.variants.map { ($0, EmacsOracle.positions($0).enumerated().filter { $0.offset % 7 == 0 || $0.element == 0 }.map(\.element)) }
        try compareWithEmacs(inputs, commands)
        try compareWithEmacs(inputs, commands, options: doomOptions)
    }

    /// M-q with an active region: `org-fill-paragraph` called interactively.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func regionFillMatchesEmacs() throws {
        try #require(EmacsOracle.isAvailable)
        let texts = [
            "Short\nlines\n\n" + Self.long + "\nmore\n\nlast\npara\n",
            "* H\nintro\ntext\n- item " + Self.long + "\n- b\n  c\n# comment\n# lines\n#\n# again\n",
            "a\nb\n#+begin_comment\none\ntwo\n\nthree\nfour\n#+end_comment\n:NOTES:\nx\ny\n:END:\n#+begin_quote\nq\nr\n#+end_quote\nz\nw\n",
            "Words  with   extra spaces\n\n  and   more\n",
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int)] = []
        for text in texts {
            let positions = EmacsOracle.positions(text)
            for (i, from) in positions.enumerated() where i % 3 == 0 {
                for to in positions where to > from && (to - from) % 5 == 1 {
                    let form = "(progn (transient-mark-mode 1) (set-mark \(EmacsOracle.point(to, in: text))) (activate-mark) (org-fill-paragraph nil t))"
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(from, in: text), form: withOptions(.org, form)))
                    let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [from..<to], options: .org)
                    guard case .commit(let result) = FillParagraph().run(in: context) else {
                        ours.append(("\(from)..<\(to) failed", text, -1))
                        continue
                    }
                    let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
                    ours.append(("\(from)..<\(to) in \(text.debugDescription)", new, result.selection?.first?.lowerBound ?? from))
                }
            }
        }
        var mismatches = 0
        for (mine, emacs) in zip(ours, try EmacsOracle.run(cases)) {
            let caret = EmacsOracle.offset(emacs.point, in: emacs.text)
            guard !emacs.error.isEmpty || mine.text != emacs.text || mine.caret != caret else { continue }
            mismatches += 1
            if mismatches <= 12 {
                Issue.record("\(mine.label)\n  ours:  \(mine.text.debugDescription) @\(mine.caret)\n  emacs: \(emacs.error.isEmpty ? "\(emacs.text.debugDescription) @\(caret)" : emacs.error)")
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(ours.count) differ")
    }

    /// Real paragraphs: `ORGSTAR_ORACLE_CORPUS=<folder>` fills the first 30 paragraph-like lines
    /// of up to 60 files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"] != nil))
    func fillMatchesEmacsOnACorpus() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORGSTAR_ORACLE_CORPUS"]!)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "org" }.sorted { $0.path < $1.path }
        var samples: [(String, [Int])] = []
        for file in files where samples.count < 60 {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.utf16.count <= 20_000, !text.contains("\\r") else { continue }
            let ns = text as NSString
            var carets: [Int] = []
            var location = 0
            var inSource = false
            while location < ns.length, carets.count < 30 {
                let line = ns.lineRange(for: NSRange(location: location, length: 0))
                let content = ns.substring(with: line)
                let lower = content.lowercased().trimmingCharacters(in: .whitespaces)
                // M-q in a src block fills through the language's mode in Emacs; Orgstar leaves code alone.
                if lower.hasPrefix("#+begin_src") { inSource = true }
                if lower.hasPrefix("#+end_src") { inSource = false }
                if !inSource, content.count > 20, !content.hasPrefix("*"), !content.hasPrefix("#+"), !content.hasPrefix("|") { carets.append(line.location + 3) }
                location = NSMaxRange(line)
            }
            if !carets.isEmpty { samples.append((text, carets)) }
        }
        let commands: [(command: any OrgCommand, form: String, headingLineOnly: Bool)] = [(FillParagraph(), "(org-fill-paragraph)", false)]
        try compareWithEmacs(samples, commands)
        try compareWithEmacs(samples, commands, options: doomOptions)
    }
}
