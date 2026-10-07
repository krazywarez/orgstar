import Foundation
import Testing
@testable import OrgCore

/// Runs a Babel job the way the app does, for tests.
struct NativeUnsupported: Error {}

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
        case .process(let executable, var arguments):
            if let script = job.script {
                let file = folder.appendingPathComponent("script")
                try script.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                arguments = arguments.map { $0.replacingOccurrences(of: Babel.scriptFileToken, with: file.path) }
            }
            process.arguments = [executable] + arguments
        case .emacs:
            let script = folder.appendingPathComponent("babel.el")
            try input.write(to: script, atomically: true, encoding: .utf8)
            process.arguments = [EmacsOracle.executable, "-Q", "--batch", "-l", script.path]
        case .session:
            return BabelOutput(stdout: "")
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
    /// `native` runs Emacs Lisp blocks with `Babel.evaluateNatively` instead of Emacs.
    static func execute(_ text: String, caret: Int, directory: URL, native: Bool = false) throws -> (text: String, failure: String?) {
        func run(_ job: BabelJob, directory: URL) throws -> BabelOutput {
            guard native else { return try TestBabelRunner.run(job, directory: directory) }
            guard let output = try Babel.evaluateNatively(job) else { throw NativeUnsupported() }
            return output
        }
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
        switch Babel.plan(context) {
        case .failure(.message(let message)): return (text, message)
        case .success(var job):
            while let need = job.needs.first {
                switch Babel.resume(job, need: need, output: try run(need.job, directory: directory), text: text, tree: context.tree) {
                case .failure(.message(let message)): return (text, message)
                case .success(let next): job = next
                }
            }
            let output: BabelOutput
            do {
                output = try run(job, directory: directory)
            } catch let failure as Babel.Failure {
                guard case .message(let message) = failure else { return (text, nil) }
                return (text, message)
            }
            if let file = Babel.fileResult(job, output: output) {
                try file.contents.write(to: directory.appendingPathComponent(file.path), atomically: true, encoding: .utf8)
            }
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
        // `:cmdline`, `:stdin` and `:shebang`.
        "#+begin_src sh :cmdline one \"two words\" :results output\nfor a in \"$@\"; do echo \"[$a]\"; done\n#+end_src\n",
        "#+begin_src sh :cmdline 3\necho $(( $1 * 2 ))\n#+end_src\n",
        "#+NAME: rows\n| a | 1 |\n| b | 2 |\n\n#+begin_src sh :stdin rows :results output\nwhile IFS=$(printf '\\t') read -r k v; do echo \"$k=$v\"; done\n#+end_src\n",
        "#+NAME: items\n- x\n- y\n\n#+begin_src sh :stdin items\nwc -l | tr -d ' '\n#+end_src\n",
        "#+begin_src bash :shebang #!/bin/bash :results output\necho ${BASH_VERSION:+bash}\n#+end_src\n",
        "#+begin_src sh :cmdline a b :padline no :var x=5 :results output\necho $x $#\n#+end_src\n",
        "#+begin_src sh :stdin src :results output\ntr a-z A-Z\n#+end_src\n\n#+NAME: src\n#+begin_src sh\necho hello\n#+end_src\n",
        // `:var` from other blocks' results.
        "#+begin_src sh :var x=five\necho $((x+1))\n#+end_src\n\n#+NAME: five\n#+begin_src sh\necho 5\n#+end_src\n",
        "#+begin_src python :var t=tbl\nreturn [len(t), t[1][0]]\n#+end_src\n\n#+NAME: tbl\n#+begin_src python\nreturn [[1, 2], [3, 4]]\n#+end_src\n",
        "#+begin_src sh :var x=double(n=4)\necho $x\n#+end_src\n\n#+NAME: double\n#+begin_src sh :var n=2\necho $((n*2))\n#+end_src\n",
        "#+begin_src python :var a=outer\nreturn a * 2\n#+end_src\n\n#+NAME: outer\n#+begin_src python :var b=inner\nreturn b + 1\n#+end_src\n\n#+NAME: inner\n#+begin_src python\nreturn 20\n#+end_src\n",
        "#+begin_src emacs-lisp :var s=greet\n(concat s \"!\")\n#+end_src\n\n#+NAME: greet\n#+begin_src emacs-lisp\n\"hi\"\n#+end_src\n",
        "#+begin_src python :var s=words\nreturn s.upper()\n#+end_src\n\n#+NAME: words\n#+begin_src sh :results output\nprintf 'two words'\n#+end_src\n",
        "#+begin_src emacs-lisp :var rows=pairs\n(length rows)\n#+end_src\n\n#+NAME: pairs\n#+begin_src sh\nprintf 'a 1\\nb 2\\nc 3\\n'\n#+end_src\n",
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

    static let lispCases = [
        "#+begin_src emacs-lisp\n(list 1 2.5 \"three\" 'four)\n#+end_src\n",
        "#+begin_src emacs-lisp\n(list '(a 1) 'hline '(b 2))\n#+end_src\n",
        "#+begin_src emacs-lisp\n(format \"%05.2f|%s\" 3.14159 'sym)\n#+end_src\n",
        "#+begin_src emacs-lisp\n\"line one\\nline \\\"two\\\"\"\n#+end_src\n",
        "#+begin_src emacs-lisp :results verbatim\n\"with \\\"quotes\\\" and \\\\ slash\"\n#+end_src\n",
        "#+begin_src emacs-lisp\nnil\n#+end_src\n",
        "#+begin_src emacs-lisp\nt\n#+end_src\n",
        "#+begin_src emacs-lisp\n[1 2 3]\n#+end_src\n",
        "#+begin_src emacs-lisp\n(cons 1 2)\n#+end_src\n",
        "#+begin_src emacs-lisp\n(/ 10 4.0)\n#+end_src\n",
        "#+begin_src emacs-lisp\n(let ((s 0)) (dotimes (i 5) (setq s (+ s i))) s)\n#+end_src\n",
        "#+begin_src emacs-lisp\n(mapcar (lambda (x) (* x x)) '(1 2 3))\n#+end_src\n",
        "#+begin_src emacs-lisp :results output\n(princ \"a\")\n(terpri)\n(prin1 \"b\")\n(print 'c)\n#+end_src\n",
        "#+begin_src emacs-lisp :results value scalar\n'(1 2)\n#+end_src\n",
        "#+begin_src emacs-lisp :results list\n'(\"x\" \"y\")\n#+end_src\n",
        "#+NAME: tbl\n| 1 | 2 |\n| 3 | 4 |\n\n#+begin_src emacs-lisp :var rows=tbl\n(mapcar (lambda (r) (apply #'+ r)) rows)\n#+end_src\n",
        "#+begin_src emacs-lisp :var n=6 :var s=\"hi\"\n(concat s (number-to-string (* n 7)))\n#+end_src\n",
        "#+begin_src emacs-lisp\n(car 1)\n#+end_src\n",
        "#+begin_src emacs-lisp :results raw\n\"*bold*\"\n#+end_src\n",
        "#+begin_src emacs-lisp :wrap example\n(upcase \"wrapped\")\n#+end_src\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func lispRunsNativelyLikeEmacs() throws {
        let folder = FileManager.default.temporaryDirectory
        let texts = Self.lispCases + Self.cases.filter { ($0.contains("emacs-lisp") || $0.contains("begin_src elisp")) && !$0.contains("begin_src sh") }
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)] = []
        for text in texts {
            let caret = (text as NSString).range(of: "#+begin_src").location + 2
            do {
                ours.append(try TestBabelRunner.execute(text, caret: caret, directory: folder, native: true))
            } catch is NativeUnsupported {
                Issue.record("not run natively:\n\(text)")
                ours.append((text, "unsupported"))
            }
            emacsCases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
            (progn
              (setq org-confirm-babel-evaluate nil)
              (org-babel-execute-src-block))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text, "case \(i):\n\(texts[i])\nours (\(mine.failure ?? "")):\n\(mine.text)\nemacs (\(theirs.error)):\n\(theirs.text)")
        }
    }

    @Test func asksOnceForEveryReferencedBlock() throws {
        let text = BabelTests.cases.first { $0.contains(":var a=outer") }!
        guard case .success(let job) = Babel.plan(EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])) else {
            Issue.record("not planned")
            return
        }
        #expect(job.needs.first?.reference == "inner")
        #expect(job.blockText.contains("return a * 2") && job.blockText.contains("return b + 1") && job.blockText.contains("return 20"))
    }

    @Test func refusesWhatWouldRunDifferently() {
        for (text, message) in [
            ("#+begin_src sh :eval never\necho\n#+end_src\n", "Evaluation of this sh code block is disabled."),
            ("#+begin_src ruby :session s\nputs 1\n#+end_src\n", ":session isn't supported for ruby yet; nothing was run."),
            ("#+begin_src sh :noweb yes\n<<x()>>\n#+end_src\n", "Noweb references that run a block (x()) aren't supported yet; nothing was run."),
            ("#+begin_src python :cmdline -x\nreturn 1\n#+end_src\n", ":cmdline isn't supported for python yet; nothing was run."),
            ("#+begin_src cobol\nDISPLAY\n#+end_src\n", "No way to run cobol blocks yet."),
            ("#+begin_src sh :var x=loop\necho\n#+end_src\n#+NAME: loop\n#+begin_src sh :var y=loop\necho\n#+end_src\n", "loop refers to itself through :var"),
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

struct BabelCallTests {
    static let named = "#+NAME: double\n#+begin_src sh :var n=2\necho $((n*2))\n#+end_src\n\n"
    static let cases: [(String, String)] = [
        (named + "#+CALL: double(n=5)\n", "#+CALL"),
        (named + "#+CALL: double()\n", "#+CALL"),
        (named + "#+CALL: double(n=5)\n\n#+RESULTS:\n: 99\n\nAfter.\n", "#+CALL"),
        (named + "#+CALL: double[:results raw](n=7)\n", "#+CALL"),
        (named + "#+CALL: double(n=3) :results verbatim\n", "#+CALL"),
        (named + "#+NAME: six\n#+CALL: double(n=3)\n", "#+CALL"),
        ("Text src_sh{echo hi} end.\n", "src_sh"),
        ("Text src_sh{echo hi} {{{results(=old=)}}} end.\n", "src_sh"),
        ("Text src_sh[:results raw]{echo raw} end.\n", "src_sh"),
        ("Text src_python{return 6*7} end.\n", "src_python"),
        ("Text src_sh[:var x=3]{echo $x} end.\n", "src_sh"),
        (named + "Inline call_double(n=6) here.\n", "call_"),
        (named + "Inline call_double() here.\n", "call_"),
        (named + "Inline call_double(n=6)[:results raw] here.\n", "call_"),
        (named + "Inline call_double[:results verbatim](n=1) here.\n", "call_"),
        (named + "Inline call_double(n=2) {{{results(=0=)}}} here.\n", "call_"),
        (named + "Inline call_double(n=2) and call_double(n=3) here.\n", "call_double(n=3"),
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        let folder = FileManager.default.temporaryDirectory
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)] = []
        for (text, at) in Self.cases {
            let caret = (text as NSString).range(of: at).location + 2
            ours.append(try TestBabelRunner.execute(text, caret: caret, directory: folder))
            emacsCases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
            (progn
              (require 'ob-shell)
              (require 'ob-python)
              (setq org-confirm-babel-evaluate nil
                    org-babel-python-command "python3"
                    default-directory temporary-file-directory)
              (org-ctrl-c-ctrl-c))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text && (mine.failure != nil) == !theirs.error.isEmpty,
                    "case \(i):\n\(Self.cases[i].0)\nours (\(mine.failure ?? "")):\n\(mine.text)\nemacs (\(theirs.error)):\n\(theirs.text)")
        }
    }
}

struct BabelFileTests {
    static let cases = [
        "#+begin_src sh :results file :file out.txt\necho hello\necho there\n#+end_src\n",
        "#+begin_src sh :results output file :file x.txt :file-desc Desc\necho out\n#+end_src\n",
        "#+begin_src sh :results file :file y.txt :file-desc\necho y\n#+end_src\n",
        "#+begin_src python :results file :file p.txt\nreturn [[1,2],[3,4]]\n#+end_src\n",
        "#+begin_src sh :results file\necho no-file.txt\n#+end_src\n",
        "#+begin_src sh :results file :file w.txt :output-dir outd\necho w\n#+end_src\n",
        "#+begin_src sh :file plain.txt\necho not to a file\n#+end_src\n",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesEmacs() throws {
        for (i, text) in Self.cases.enumerated() {
            let ours = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-file-ours-\(UUID().uuidString)")
            let theirs = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-file-emacs-\(UUID().uuidString)")
            for folder in [ours, theirs] { try FileManager.default.createDirectory(at: folder.appendingPathComponent("outd"), withIntermediateDirectories: true) }
            defer { for folder in [ours, theirs] { try? FileManager.default.removeItem(at: folder) } }
            let mine = try TestBabelRunner.execute(text, caret: 2, directory: ours)
            let emacs = try EmacsOracle.run([EmacsOracle.Case(text: text, point: 3, form: """
                (progn (require 'ob-shell) (require 'ob-python)
                  (setq org-confirm-babel-evaluate nil org-babel-python-command "python3" default-directory \(lispString(theirs.path + "/")))
                  (org-babel-execute-src-block))
                """)])[0]
            #expect(mine.text == emacs.text, "case \(i)\nours: \(mine.text) \(mine.failure ?? "")\nemacs: \(emacs.text) \(emacs.error)")
            for name in ["out.txt", "x.txt", "y.txt", "p.txt", "outd/w.txt", "plain.txt"] {
                let a = try? String(contentsOf: ours.appendingPathComponent(name), encoding: .utf8)
                let b = try? String(contentsOf: theirs.appendingPathComponent(name), encoding: .utf8)
                #expect(a == b, "case \(i) \(name): \(a.debugDescription) vs \(b.debugDescription)")
            }
        }
    }

    @Test func plansDiagrams() throws {
        let text = "#+begin_src dot :file g.svg\ndigraph { a -> b }\n#+end_src\n"
        guard case .success(let job) = Babel.plan(EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])) else {
            Issue.record("not planned")
            return
        }
        #expect(job.runner == .process(executable: "/bin/sh", arguments: ["-c", "dot -Tsvg -o 'g.svg'"]))
        guard case .success(let edits) = Babel.finish(job, output: BabelOutput(stdout: ""), text: text) else { return }
        let new = edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
        #expect(new.hasSuffix("#+RESULTS:\n[[file:g.svg]]\n"))
        #expect(Babel.fileResult(job, output: BabelOutput(stdout: "")) == nil)
        let uml = "#+begin_src plantuml :file u.png\nA -> B\n#+end_src\n"
        guard case .success(let umlJob) = Babel.plan(EditContext(revision: 0, text: uml, tree: OrgParser.parse(uml), selection: [2..<2])) else { return }
        #expect(umlJob.input == "@startuml\nA -> B\n@enduml\n")
    }
}
