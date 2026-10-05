import Foundation
import Testing
@testable import OrgCore

/// Runs a Babel job the way the app does, for tests.
enum TestBabelRunner {
    static func run(_ job: BabelJob, directory: URL) throws -> BabelOutput {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-babel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resultFile = folder.appendingPathComponent("result")
        let input = job.input.replacingOccurrences(of: Babel.resultFileToken, with: resultFile.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        switch job.runner {
        case .process(let executable, let arguments):
            process.arguments = [executable] + arguments
        case .emacs:
            let script = folder.appendingPathComponent("babel.el")
            try input.write(to: script, atomically: true, encoding: .utf8)
            process.arguments = [EmacsOracle.executable, "-Q", "--batch", "-l", script.path]
        }
        process.currentDirectoryURL = job.directory.map { URL(fileURLWithPath: $0, relativeTo: directory) } ?? directory
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        if case .process = job.runner { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return BabelOutput(stdout: String(decoding: data, as: UTF8.self), resultFile: try? String(contentsOf: resultFile, encoding: .utf8))
    }

    /// Plans, runs and finishes the block at `caret`: the new text, or the failure.
    static func execute(_ text: String, caret: Int, directory: URL) throws -> (text: String, failure: String?) {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
        switch Babel.plan(context) {
        case .failure(.message(let message)): return (text, message)
        case .success(let job):
            let output = try run(job, directory: directory)
            switch Babel.finish(job, output: output, text: text) {
            case .failure(.message(let message)): return (text, message)
            case .success(let edits):
                var new = text
                for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
                return (new, nil)
            }
        }
    }
}

struct BabelTests {
    static let cases: [String] = [
        "#+begin_src sh\necho hello\n#+end_src\n",
        "#+begin_src sh\necho hello\n#+end_src\nNext paragraph.\n",
        "#+begin_src sh\necho hello\n#+end_src\n\nNext paragraph.\n",
        "#+begin_src sh\necho hello\n#+end_src",
        "#+begin_src sh\necho one; echo two\n#+end_src\n",
        "#+begin_src sh\nprintf 'a b c\\nd e f\\n'\n#+end_src\n",
        "#+begin_src sh\nprintf 'a\\tb\\nc\\td\\n'\n#+end_src\n",
        "#+begin_src sh\nprintf '1,2\\n3,4\\n'\n#+end_src\n",
        "#+begin_src sh :results output\nprintf 'a b c\\nd e f\\n'\n#+end_src\n",
        "#+begin_src sh :results output\nseq 1 12\n#+end_src\n",
        "#+begin_src sh :results output\nprintf '* not a heading\\n#+not a keyword\\n'\nseq 1 9\n#+end_src\n",
        "#+begin_src sh :results value\necho hi\n#+end_src\n",
        "#+begin_src sh :results verbatim\necho 007\n#+end_src\n",
        "#+begin_src sh\necho 007\n#+end_src\n",
        "#+begin_src sh :results raw\necho '*bold*'\n#+end_src\n",
        "#+begin_src sh :results drawer\necho in a drawer\n#+end_src\n",
        "#+begin_src sh :results list\nprintf 'a\\nb\\n'\n#+end_src\n",
        "#+begin_src sh :results silent\necho quiet\n#+end_src\n",
        "#+begin_src sh :results output code\necho 'x=1'\n#+end_src\n",
        "#+begin_src sh :wrap example\necho wrapped\n#+end_src\n",
        "#+begin_src sh\necho new\n#+end_src\n\n#+RESULTS:\n: old\n\nAfter.\n",
        "#+begin_src sh\necho new\n#+end_src\n#+RESULTS:\n| old | table |\n| a   | b     |\nAfter.\n",
        "#+begin_src sh :results append\necho more\n#+end_src\n\n#+RESULTS:\n: first\n",
        "#+NAME: greet\n#+begin_src sh\necho named\n#+end_src\n\nText.\n\n#+RESULTS: greet\n: stale\n",
        "#+NAME: fresh\n#+begin_src sh\necho named\n#+end_src\n",
        "- item\n  #+begin_src sh\n  echo indented\n  #+end_src\n",
        "#+begin_src sh :var x=5 :var y=\"two words\"\necho $x $y\n#+end_src\n",
        "#+begin_src bash\necho ${BASH_VERSION:+bash}\n#+end_src\n",
        "#+begin_src sh :results output\n#+end_src\n",
        "#+begin_src sh\nprintf ''\n#+end_src\n",
        "#+begin_src python\nreturn 42\n#+end_src\n",
        "#+begin_src python\nreturn 'hello'\n#+end_src\n",
        "#+begin_src python\nreturn [[1, 2], [3, 4]]\n#+end_src\n",
        "#+begin_src python\nreturn [1, 'a', 2.5]\n#+end_src\n",
        "#+begin_src python\nreturn 1/3\n#+end_src\n",
        "#+begin_src python\nx = 2\nif x:\n    return x * 21\n#+end_src\n",
        "#+begin_src python :results output\nprint('one')\nprint('two')\n#+end_src\n",
        "#+begin_src python :results output\nfor i in range(12): print(i)\n#+end_src\n",
        "#+begin_src python :var n=3 :var s=\"hi\"\nreturn s * n\n#+end_src\n",
        "#+NAME: nums\n| 1 | 2 |\n| 3 | 4 |\n\n#+begin_src python :var t=nums\nreturn [[c * 10 for c in r] for r in t]\n#+end_src\n",
        "#+begin_src python :results list\nreturn ['a', 'b']\n#+end_src\n",
        "#+begin_src python :results verbatim\nreturn [1, 2]\n#+end_src\n",
        "#+begin_src python\ns = '''multi\n  line'''\nreturn s\n#+end_src\n",
        "#+begin_src python\nreturn None\n#+end_src\n",
        "#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n",
        "#+begin_src emacs-lisp\n'((1 2) (3 4))\n#+end_src\n",
        "#+begin_src elisp\n(concat \"a\" \"b\")\n#+end_src\n",
        "#+begin_src emacs-lisp :results verbatim\n\"quoted\"\n#+end_src\n",
        "#+begin_src emacs-lisp :results output\n(princ \"printed\")\n#+end_src\n",
        "#+begin_src emacs-lisp :var x=4\n(* x x)\n#+end_src\n",
        "#+PROPERTY: header-args :results output\n#+begin_src sh\nprintf 'a b\\nc d\\n'\n#+end_src\n",
        "* Heading\n:PROPERTIES:\n:header-args:sh: :results verbatim\n:END:\n#+begin_src sh\necho 1 2\n#+end_src\n",
        "#+HEADER: :results output\n#+begin_src sh\nprintf 'x y\\nz w\\n'\n#+end_src\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let folder = FileManager.default.temporaryDirectory
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)] = []
        for text in Self.cases {
            let caret = (text as NSString).range(of: "#+begin_src").location + 2
            ours.append(try TestBabelRunner.execute(text, caret: caret, directory: folder))
            emacsCases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
            (progn
              (require 'ob-shell)
              (require 'ob-python)
              (require 'ob-emacs-lisp)
              (setq org-confirm-babel-evaluate nil
                    org-babel-python-command "python3"
                    default-directory temporary-file-directory)
              (org-babel-execute-src-block))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text, "case \(i):\n\(Self.cases[i])\nours (\(mine.failure ?? "")):\n\(mine.text)\nemacs (\(theirs.error)):\n\(theirs.text)")
        }
    }

    @Test func refusesWhatWouldRunDifferently() {
        for (text, message) in [
            ("#+begin_src sh :eval never\necho\n#+end_src\n", "Evaluation of this sh code block is disabled."),
            ("#+begin_src sh :session s\necho\n#+end_src\n", ":session isn't supported yet; nothing was run."),
            ("#+begin_src sh :noweb yes\necho\n#+end_src\n", ":noweb isn't supported yet; nothing was run."),
            ("#+begin_src sh :file out.txt\necho\n#+end_src\n", ":file isn't supported yet; nothing was run."),
            ("#+begin_src cobol\nDISPLAY\n#+end_src\n", "No way to run cobol blocks yet."),
        ] {
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
            guard case .failure(.message(let got)) = Babel.plan(context) else {
                Issue.record("ran: \(text)")
                continue
            }
            #expect(got == message)
        }
    }
}
