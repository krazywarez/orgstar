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
