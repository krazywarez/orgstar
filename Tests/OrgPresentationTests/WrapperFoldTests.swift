import Foundation
import Testing
import OrgCore
@testable import OrgPresentation

/// Drawer and block folding against Emacs: the visible text after opening a file and after
/// each TAB or Shift-TAB, with Doom's `org-startup-folded` nil.
struct WrapperFoldTests {
    static let texts = [
        "* A\n:PROPERTIES:\n:ID: x\n:END:\nbody\n#+begin_src sh\necho\n#+end_src\n* B\n:LOGBOOK:\n- State \"DONE\" from \"TODO\"\n:END:\ntext\n",
        "#+STARTUP: hideblocks\n:PROPERTIES:\n:CATEGORY: c\n:END:\n* A\n#+begin_quote\nq\n#+end_quote\n\n#+begin_example\ne\n#+end_example\n",
        "#+STARTUP: nohidedrawers\n* A\n:NOTES:\nn\n:END:\n#+begin_src sh\n#+end_src\n",
        "#+STARTUP: overview\n* A\n:PROPERTIES:\n:X: 1\n:END:\n** B\n:LOGBOOK:\nl\n:END:\n",
        "* A\n:DRAWER:\n#+begin_src sh\necho\n#+end_src\n:END:\n",
    ]

    /// `T:text` presses TAB at the start of `text`; `G` presses Shift-TAB. Emacs cycles a heading
    /// by the previous command and Orgstar by its fold state; they agree on repeated TABs on
    /// one heading, so steps don't go back to a heading after other steps.
    static let steps = [
        ["T::PROPERTIES:", "T::PROPERTIES:", "T:#+begin_src", "T:#+end_src", "T:* A", "T:* A", "G", "G", "G", "G"],
        ["T::END:", "T:#+begin_quote", "T:#+end_quote", "T:q\n", "G", "G", "G"],
        ["T::NOTES:", "T::END:", "T:#+begin_src", "G", "G", "G"],
        ["T:* A", "T:* A", "T::LOGBOOK:", "G", "G", "G"],
        ["T::DRAWER:", "T::DRAWER:", "T:#+begin_src", "T::DRAWER:", "T::DRAWER:"],
    ]

    static func visible(_ text: String, _ hidden: [Range<Int>]) -> String {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        for (i, unit) in units.enumerated() where !hidden.contains(where: { $0.contains(i) }) { out.append(unit) }
        return String(decoding: out, as: UTF16.self)
    }

    static func ours(_ text: String, _ steps: [String]) -> [String] {
        let tree = OrgParser.parse(text)
        var state = Presentation.startupFoldState(tree) ?? FoldState()
        state.wrapperFolds = Presentation.startupWrapperFolds(tree)
        var global: GlobalVisibility?
        func show() -> String {
            visible(text, Presentation.hiddenRanges(tree, folds: state.folds, bodyFolds: state.bodyFolds, wrapperFolds: state.wrapperFolds))
        }
        var out = [show()]
        for step in steps {
            if step == "G" {
                let (next, folds) = Presentation.cycleGlobal(from: global, in: tree, wrapperFolds: state.wrapperFolds)
                global = next
                state = folds
            } else {
                global = nil
                let offset = (text as NSString).range(of: String(step.dropFirst(2))).location
                state = Presentation.cycle(at: offset, in: tree, state) ?? state
            }
            out.append(show())
        }
        return out
    }

    static func lisp(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func emacs(_ text: String, _ steps: [String]) throws -> [String] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-fold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("f.org")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let output = folder.appendingPathComponent("out.json")
        let actions = steps.enumerated().map { i, step in
            let repeated = i > 0 && steps[i - 1] == step
            return step == "G"
                ? "(progn (setq this-command 'org-shifttab) (org-cycle '(4)) (setq last-command 'org-shifttab))"
                : "(progn (setq last-command \(repeated ? "'org-cycle" : "nil") this-command 'org-cycle) (goto-char (point-min)) (search-forward \(lisp(String(step.dropFirst(2))))) (goto-char (match-beginning 0)) (org-cycle))"
        }
        let script = folder.appendingPathComponent("fold.el")
        try """
            ;;; -*- lexical-binding: t -*-
            (require 'org)
            (require 'json)
            (setq org-startup-folded nil)
            (defun vis () (let (s) (dotimes (i (1- (point-max))) (unless (invisible-p (1+ i)) (push (char-after (1+ i)) s))) (concat (nreverse s))))
            (with-current-buffer (find-file-noselect "\(file.path)")
              (let ((out (list (vis))))
                \(actions.map { "(progn \($0) (push (vis) out))" }.joined(separator: "\n    "))
                (with-temp-file (getenv "ORACLE_OUTPUT") (insert (json-encode (vconcat (nreverse out)))))))
            """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs", "-Q", "--batch", "-l", script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["ORACLE_OUTPUT": output.path]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: output))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func foldsLikeOrg() throws {
        for (text, steps) in zip(Self.texts, Self.steps) {
            let emacs = try Self.emacs(text, steps)
            let ours = Self.ours(text, steps)
            for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
                #expect(mine == theirs, "after \(i == 0 ? "opening" : steps[i - 1]) in \(text.debugDescription)\nours:  \(mine.debugDescription)\nemacs: \(theirs.debugDescription)")
            }
            #expect(ours.count == emacs.count)
        }
    }

    @Test func togglesFromOpeningAndClosingLines() {
        let text = "* A\n:PROPERTIES:\n:ID: x\n:END:\n\n"
        let tree = OrgParser.parse(text)
        #expect(Wrappers.toggleable(at: 4, in: tree)?.start == 4)
        #expect(Wrappers.toggleable(at: 18, in: tree) == nil)
        #expect(Wrappers.toggleable(at: 25, in: tree)?.hidden == 17..<30)
        #expect(Wrappers.toggleable(at: 30, in: tree) == nil)
    }
}
