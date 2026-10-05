import Foundation
import Testing
@testable import OrgCore

struct RefileTests {
    @Test func withinFile() {
        let text = "* a\nx\n* b\n** c\n"
        #expect(runCommand(RefileWithinFile(), text, caret: 0, answers: ["refile": "6"]).text == "* b\n** c\n** a\nx\n")
        #expect(runCommand(RefileWithinFile(), text, caret: 0, answers: ["refile": "0"]).failure != nil)
        #expect(runCommand(RefileWithinFile(), "* a\n* b\n", caret: 0, answers: ["refile": ""]).text == "* b\n* a\n")
    }

    @Test func toAnotherFile() throws {
        let source = "* a :t:\nbody\n* b\n"
        let context = EditContext(revision: 0, text: source, tree: OrgParser.parse(source), selection: [0..<0])
        let result = try #require(Refile.toOtherFile(source: context, target: "* inbox\n", under: 0))
        #expect(result.target.apply(to: "* inbox\n").hasPrefix("* inbox\n** a"))
        #expect(result.source.edits.first?.apply(to: source) == "* b\n")
    }

    static let variants = [
        "* a\nbody\n* b\n** c\n* d\n",
        "* a\n\n* b\n\n** c\n\n* d\n",
        "intro\n* TODO a :x:\n** sub\n* b\n",
        "* a\n** b\n*** c\n* d",
    ]

    /// Emacs needs files to refile; each case writes the text to a temporary file and refiles there.
    static func sameFileForm(_ target: Int?) -> String {
        """
        (let* ((f (make-temp-file "orgstar" nil ".org")) (p (point)) s)
          (write-region (point-min) (point-max) f)
          (with-current-buffer (find-file-noselect f)
            (org-fold-show-all) (goto-char p)
            (org-refile nil nil (list "t" f nil \(target.map { String($0 + 1) } ?? "nil")))
            (setq p (point) s (buffer-string))
            (set-buffer-modified-p nil) (kill-buffer))
          (delete-file f)
          (erase-buffer) (insert s) (goto-char p))
        """
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func refileWithinFileMatchesEmacs() throws {
        try #require(EmacsOracle.isAvailable)
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int, failed: Bool)] = []
        for text in Self.variants {
            let tree = OrgParser.parse(text)
            let targets: [Int?] = [nil] + tree.root.descendants().filter { $0.kind == .heading }.map(\.range.lowerBound)
            for caret in EmacsOracle.positions(text) where entryHeading(at: caret, in: tree) != nil {
                for target in targets {
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: Self.sameFileForm(target)))
                    let result = runCommand(RefileWithinFile(), text, caret: caret, answers: ["refile": target.map(String.init) ?? ""])
                    ours.append(("to \(target.map(String.init) ?? "end") at \(caret) in \(text.debugDescription)", result.text, result.caret, result.failure != nil))
                }
            }
        }
        var mismatches = 0
        for (mine, emacs) in zip(ours, try EmacsOracle.run(cases)) {
            let failed = !emacs.error.isEmpty
            let caret = EmacsOracle.offset(emacs.point, in: emacs.text)
            guard mine.failed != failed || (!failed && (mine.text != emacs.text || mine.caret != caret)) else { continue }
            mismatches += 1
            if mismatches <= 10 {
                Issue.record("\(mine.label)\n  ours:  \(mine.failed ? "failed" : "\(mine.text.debugDescription) @\(mine.caret)")\n  emacs: \(failed ? emacs.error : "\(emacs.text.debugDescription) @\(caret)")")
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(ours.count) differ")
    }

    static let separator = "\n@@@@\n"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func refileToAnotherFileMatchesEmacs() throws {
        try #require(EmacsOracle.isAvailable)
        let targetTexts = ["* inbox\n", "* p\n** q\n* r :t:\n", "", "text only\n", "* p\n\n* r\n"]
        var cases: [EmacsOracle.Case] = []
        var ours: [(label: String, text: String, caret: Int, failed: Bool)] = []
        for source in Self.variants {
            let tree = OrgParser.parse(source)
            for caret in EmacsOracle.positions(source) where entryHeading(at: caret, in: tree) != nil {
                for targetText in targetTexts {
                    let targetTree = OrgParser.parse(targetText)
                    let headings: [Int?] = [nil] + targetTree.root.descendants().filter { $0.kind == .heading }.map(\.range.lowerBound)
                    for heading in headings {
                        let escaped = targetText.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                        let form = """
                            (let* ((f1 (make-temp-file "orgstar" nil ".org")) (f2 (make-temp-file "orgstar" nil ".org" "\(escaped)")) (p (point)) s1 s2)
                              (write-region (point-min) (point-max) f1)
                              (let ((b2 (find-file-noselect f2)))
                                (with-current-buffer (find-file-noselect f1)
                                  (org-fold-show-all) (goto-char p)
                                  (org-refile nil nil (list "t" f2 nil \(heading.map { String($0 + 1) } ?? "nil")))
                                  (setq p (point) s1 (buffer-string))
                                  (set-buffer-modified-p nil) (kill-buffer))
                                (with-current-buffer b2 (setq s2 (buffer-string)) (set-buffer-modified-p nil) (kill-buffer)))
                              (delete-file f1) (delete-file f2)
                              (erase-buffer) (insert s1 "\(Self.separator.replacingOccurrences(of: "\n", with: "\\n"))" s2) (goto-char p))
                            """
                        cases.append(EmacsOracle.Case(text: source, point: EmacsOracle.point(caret, in: source), form: form))
                        let context = EditContext(revision: 0, text: source, tree: tree, selection: [caret..<caret])
                        if let result = Refile.toOtherFile(source: context, target: targetText, under: heading) {
                            let newSource = result.source.edits.reduce(source) { $1.apply(to: $0) }
                            let caretAfter = result.source.selection?.first?.lowerBound ?? caret
                            ours.append(("to \(heading.map(String.init) ?? "end") of \(targetText.debugDescription) at \(caret) in \(source.debugDescription)", newSource + Self.separator + result.target.apply(to: targetText), caretAfter, false))
                        } else {
                            ours.append(("failed", "", 0, true))
                        }
                    }
                }
            }
        }
        var mismatches = 0
        for (mine, emacs) in zip(ours, try EmacsOracle.run(cases)) {
            let failed = !emacs.error.isEmpty
            let caret = EmacsOracle.offset(emacs.point, in: emacs.text)
            guard mine.failed != failed || (!failed && (mine.text != emacs.text || mine.caret != caret)) else { continue }
            mismatches += 1
            if mismatches <= 10 {
                Issue.record("\(mine.label)\n  ours:  \(mine.failed ? "failed" : "\(mine.text.debugDescription) @\(mine.caret)")\n  emacs: \(failed ? emacs.error : "\(emacs.text.debugDescription) @\(caret)")")
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(ours.count) differ")
    }
}
