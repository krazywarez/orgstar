import Foundation
import Testing
@testable import OrgCore

/// C, C++, D, Java, Fortran and Clojure blocks (ob-C, ob-java, ob-fortran, ob-clojure).
struct BabelCompiledTests {
    static func installed(_ program: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(program)")
        }
    }

    static let table = "#+NAME: tbl\n| a | b |\n|---+---|\n| 1 | 2 |\n| 3 | 4 |\n\n"

    /// Compiled and run here and in Emacs.
    static let cases: [String] = [
        "#+begin_src C :includes <stdio.h>\nprintf(\"hello\\n\");\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :results output\nprintf(\"a b\\nc d\\n\");\n#+end_src\n",
        "#+begin_src C :includes <stdio.h>\nprintf(\"a b\\nc d\\n\");\n#+end_src\n",
        "#+begin_src C :includes <stdio.h>\nprintf(\"1\\t2\\n3\\t4\\n\");\n#+end_src\n",
        "#+begin_src C :includes <stdio.h>\nprintf(\"  x\\n   y\\n\");\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :results output\nprintf(\"  x\\n   y\\n\");\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :results verbatim\nprintf(\"007\\n\");\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :results raw\nprintf(\"*bold*\\n\");\n#+end_src\n",
        "#+begin_src C :includes '(<stdio.h> <string.h>) :var n=3 x=2.5 s=\"hi\"\nprintf(\"%d %.1f %s %zu\\n\", n, x, s, strlen(s));\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :var l='(1 2 3)\nint s = 0; for (int i = 0; i < l_cols; i++) s += l[i]; printf(\"%d\\n\", s);\n#+end_src\n",
        table + "#+begin_src C :var t=tbl :includes <stdio.h>\nfor (int i = 0; i < t_rows; i++) printf(\"%d %d\\n\", t[i][0], t_h(i, \"b\"));\n#+end_src\n",
        table + "#+begin_src C :var t=tbl :includes <stdio.h> :colnames yes\nfor (int i = 0; i < t_rows; i++) printf(\"%d %d\\n\", t[i][1], t[i][0]);\n#+end_src\n",
        "#+NAME: rt\n| r1 | 1 |\n| r2 | 2 |\n\n#+begin_src C :var t=rt :includes <stdio.h> :rownames yes\nfor (int i = 0; i < t_rows; i++) printf(\"%d\\n\", t[i][0] * 10);\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :main no\nint main() { printf(\"own main\\n\"); return 0; }\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :main no\nint main(int argc, char **argv) { printf(\"%d\\n\", argc); return 0; }\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :cmdline one \"two words\" :results output\nint main(int argc, char **argv) { for (int i = 1; i < argc; i++) printf(\"[%s]\\n\", argv[i]); return 0; }\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :flags -DN=5 -O2\nprintf(\"%d\\n\", N * 2);\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> <math.h> :libs -lm\nprintf(\"%.3f\\n\", sqrt(2.0));\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :defines N 3 M 4\nprintf(\"%d\\n\", N * M);\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :prologue int k = 6; :epilogue printf(\"%d\\n\", k);\nk *= 7;\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> <unistd.h> :dir /tmp :results output\nchar b[1024]; getcwd(b, sizeof b); printf(\"%s\\n\", b);\n#+end_src\n",
        "#+begin_src C :includes <stdio.h>\nint c = getchar(); printf(\"%d\\n\", c);\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :results output\nprintf(\"out\\n\"); fprintf(stderr, \"err\\n\"); return 3;\n#+end_src\n",
        "#+begin_src C\nsyntax error\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :session s\nprintf(\"no session\\n\");\n#+end_src\n",
        "#+begin_src C++ :includes <iostream> :namespaces std\ncout << \"c++ \" << 6 * 7 << endl;\n#+end_src\n",
        "#+begin_src cpp :includes <iostream> :var v='(1.5 2.5)\nstd::cout << v[0] + v[1] << std::endl;\n#+end_src\n",
        "#+begin_src C++ :includes <iostream> <vector> :results output :wrap example\nstd::vector<int> v{1, 2, 3}; for (int x : v) std::cout << x << \"\\n\";\n#+end_src\n",
        "* Heading\n:PROPERTIES:\n:libs: -lm\n:END:\n#+begin_src C :includes <stdio.h> <math.h>\nprintf(\"%.0f\\n\", pow(2, 10));\n#+end_src\n",
        "#+NAME: words\n| x | yy |\n| zzz | w |\n\n#+begin_src C :var t=words :includes <stdio.h> <string.h>\nprintf(\"%s %zu\\n\", t[1][0], strlen(t[0][1]));\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :results output list\nprintf(\"a\\nb\\n\");\n#+end_src\n",
        "#+begin_src C :includes <stdio.h> :var x=gen\nprintf(\"%d\\n\", x + 1);\n#+end_src\n\n#+NAME: gen\n#+begin_src C :includes <stdio.h>\nprintf(\"41\\n\");\n#+end_src\n",
    ]

    static let emacsSetup = """
        (require 'ob-C) (require 'ob-java) (require 'ob-fortran) (require 'ob-clojure)
        (setq org-confirm-babel-evaluate nil org-babel-clojure-backend 'babashka)
        """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil && installed("gcc") && installed("g++")))
    func compiledMatchEmacs() throws {
        let folder = FileManager.default.temporaryDirectory
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [(text: String, failure: String?)] = []
        for text in Self.cases {
            let caret = (text as NSString).range(of: "#+begin_src").location + 2
            ours.append(try TestBabelRunner.execute(text, caret: caret, directory: folder))
            emacsCases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
            (progn \(Self.emacsSetup)
              (setq default-directory temporary-file-directory)
              (org-babel-execute-src-block))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine.text == theirs.text, "case \(i):\n\(Self.cases[i])\nours (\(mine.failure ?? "")):\n\(mine.text)\nemacs (\(theirs.error)):\n\(theirs.text)")
        }
    }

    /// Blocks whose toolchain may not be installed, with the output the program would give:
    /// the source each writes and the result each inserts, compared with Emacs's.
    static let canned: [(text: String, output: String)] = [
        ("#+begin_src D :var n=3\nwriteln(n);\n#+end_src\n", "3\n"),
        ("#+begin_src D :imports std.math :var x=2.0\nwriteln(sqrt(x));\n#+end_src\n", "1.41421\n"),
        (table + "#+begin_src D :var t=tbl\nforeach (r; t) writeln(r[0], \" \", t_h(0, \"b\"));\n#+end_src\n", "1 2\n3 2\n"),
        ("* H\n:PROPERTIES:\n:IMPORTS: std.range\n:END:\n#+begin_src D :cmdline x y :flags -O\nwriteln(iota(3));\n#+end_src\n", "[0, 1, 2]\n"),
        ("#+begin_src java\nSystem.out.println(\"hi\");\n#+end_src\n", "hi\n"),
        ("#+begin_src java :results output\nSystem.out.println(\"a b\");\nSystem.out.println(\"c d\");\n#+end_src\n", "a b\nc d\n"),
        ("#+begin_src java :results value\nreturn 42;\n#+end_src\n", "42"),
        ("#+begin_src java :results value\nreturn \"hello\";\n#+end_src\n", "\"hello\""),
        ("#+begin_src java :results value\nreturn Arrays.asList(1, 2, 3);\n#+end_src\n", "[1,2,3]"),
        ("#+begin_src java :results value\nreturn Arrays.asList(Arrays.asList(1, 2), Arrays.asList(3, 4));\n#+end_src\n", "[[1,2],[3,4]]"),
        ("#+begin_src java :results value\nreturn new Object[] {1, null};\n#+end_src\n", "[1,null]"),
        ("#+begin_src java :results value\nreturn new Object[] {new Object[] {\"x\", 1}, null, new Object[] {\"y\", 2}};\n#+end_src\n", "[[\"x\",1],null,[\"y\",2]]"),
        ("#+begin_src java :results value verbatim\nreturn Arrays.asList(1, 2);\n#+end_src\n", "[1,2]"),
        (table + "#+begin_src java :var t=tbl :results value\nreturn t.get(1).get(0);\n#+end_src\n", "3"),
        ("#+begin_src java :var n=3 s=\"x\" x=1.5 :imports java.util.ArrayList\nSystem.out.println(n + s + x);\n#+end_src\n", "3x1.5\n"),
        ("#+begin_src java :classname pkg.Hello\nSystem.out.println(\"pkg\");\n#+end_src\n", "pkg\n"),
        ("#+begin_src java\npackage org.ex;\n\npublic class Thing {\n    public static void main(String[] args) {\n        System.out.println(\"thing\");\n    }\n}\n#+end_src\n", "thing\n"),
        ("#+begin_src java :results value\npublic class Calc {\n    static int twice(int x) {\n        return x * 2;\n    }\n    public static void main(String[] args) {\n        return twice(21);\n    }\n}\n#+end_src\n", "42"),
        ("#+begin_src java\npublic class NoMain {\n    static int x = 1;\n}\n#+end_src\n", "success"),
        ("#+begin_src java :dir /tmp :cmdline -ea :cmdargs one two :cmpflag -g\nSystem.out.println(args.length);\n#+end_src\n", "2\n"),
        ("#+begin_src fortran\nprint *, \"hello\"\n#+end_src\n", " hello\n"),
        ("#+begin_src fortran :var n=3\nprint *, n * 14\n#+end_src\n", "          42\n"),
        ("#+begin_src fortran :results output\nprint *, 1, 2\nprint *, 3, 4\n#+end_src\n", "           1           2\n           3           4\n"),
        ("#+begin_src fortran\nprint *, 1, 2\nprint *, 3, 4\n#+end_src\n", "           1           2\n           3           4\n"),
        ("#+begin_src fortran :results verbatim\nprint *, \"007\"\n#+end_src\n", " 007\n"),
        ("#+begin_src fortran :var x=2.5 s=\"ab\" :flags -O2 :cmdline q\nprint *, x, s\n#+end_src\n", "   2.50000000     ab\n"),
        (table + "#+begin_src fortran :var t=tbl\nprint *, t(2,1)\n#+end_src\n", "   3.00000000    \n"),
        ("#+begin_src fortran :main no\nprogram p\nprint *, 'p'\nend program p\n#+end_src\n", " p\n"),
        ("#+begin_src fortran :includes \"x.inc\" :defines N 2\nprint *, N\n#+end_src\n", "           2\n"),
        ("* H\n:PROPERTIES:\n:INCLUDES: \"y.inc\"\n:END:\n#+begin_src fortran\nprint *, 1\n#+end_src\n", "           1\n"),
        ("#+begin_src clojure\n(+ 40 2)\n#+end_src\n", "42\n"),
        ("#+begin_src clojure\n(str \"a\" \"b\")\n#+end_src\n", "\"ab\"\n"),
        ("#+begin_src clojure\n[1 2 3]\n#+end_src\n", "[1 2 3]\n"),
        ("#+begin_src clojure\n'(1 2)\n#+end_src\n", "(1 2)\n"),
        ("#+begin_src clojure\n{:a 1}\n#+end_src\n", "{:a 1}\n"),
        ("#+begin_src clojure\nnil\n#+end_src\n", "nil\n"),
        ("#+begin_src clojure :results output\n(println \"a\")\n(println \"b\")\n#+end_src\n", "a\nb\n"),
        ("#+begin_src clojure :var x=3 l='(1 2)\n;; comment\n(apply + x l)\n#+end_src\n", "6\n"),
        ("#+begin_src clojure :results pp\n{:a 1 :b 2}\n#+end_src\n", "{:a 1, :b 2}\n"),
        ("#+begin_src clojure :ns demo :results verbatim\n(str *ns*)\n#+end_src\n", "\"demo\"\n"),
        (table + "#+begin_src clojure :var t=tbl\n(count t)\n#+end_src\n", "2\n"),
    ]

    static let sourceMark = "\n-----SOURCE-----\n"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func cannedMatchEmacs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-compiled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var emacsCases: [EmacsOracle.Case] = []
        var ours: [String] = []
        for (text, output) in Self.canned {
            let caret = (text as NSString).range(of: "#+begin_src").location + 2
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
            switch Babel.plan(context) {
            case .failure(.message(let message)):
                ours.append("failed: \(message)")
            case .success(let job):
                guard case .success(let edits) = Babel.finish(job, output: BabelOutput(stdout: output, resultFile: output), text: text) else {
                    ours.append("not finished")
                    break
                }
                let new = edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
                ours.append(new + Self.sourceMark + job.input)
            }
            emacsCases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(caret, in: text), form: """
            (let (source)
              \(Self.emacsSetup)
              (setq default-directory \(Babel.lispString(folder.path + "/")))
              (advice-add 'org-babel-eval :override (lambda (&rest _) \(Babel.lispString(output))) '((name . canned)))
              (advice-add 'org-babel-eval-read-file :override (lambda (&rest _) \(Babel.lispString(output))) '((name . canned)))
              (advice-add 'write-region :before
                          (lambda (start end file &rest _)
                            (when (string-match-p "\\\\(C-src-\\\\|fortran-src-\\\\|clojure-cmd-script-\\\\|\\\\.java\\\\'\\\\)" file)
                              (setq source (cond ((stringp start) start) (start (buffer-substring-no-properties start end)) (t (buffer-string))))))
                          '((name . capture)))
              (unwind-protect (org-babel-execute-src-block)
                (advice-remove 'org-babel-eval 'canned)
                (advice-remove 'org-babel-eval-read-file 'canned)
                (advice-remove 'write-region 'capture))
              (goto-char (point-max))
              (insert \(Babel.lispString(Self.sourceMark))
                      (replace-regexp-in-string "FileWriter(\\"[^\\"]*\\")" \(Babel.lispString("FileWriter(\"\(Babel.resultFileToken)\")")) (or source "") t t)))
            """))
        }
        let emacs = try EmacsOracle.run(emacsCases)
        for (i, (mine, theirs)) in zip(ours, emacs).enumerated() {
            #expect(mine == theirs.text, "case \(i):\n\(Self.canned[i].text)\nours:\n\(mine)\nemacs (\(theirs.error)):\n\(theirs.text)")
        }
    }

    static func job(_ text: String) -> BabelJob? {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { return nil }
        return job
    }

    @Test func plansCompileAndRun() throws {
        let c = try #require(Self.job("#+begin_src C :flags -O2 :libs -lm :cmdline a b\nreturn 0;\n#+end_src\n"))
        #expect(c.runner == .process(executable: "/bin/sh", arguments: [Babel.scriptFileToken]))
        #expect(c.programs == [["gcc"]])
        #expect(c.script == "d=$(mktemp -d) || exit 1\ncat > \"$d/C-src.c\"\necho | gcc -o \"$d/C-bin\" -O2 \"$d/C-src.c\" -lm > /dev/null\necho | \"$d/C-bin\" a b\ns=$?\nrm -rf \"$d\"\nexit $s\n")
        #expect(c.input == "\n\n\n\n\n\n\nint main() {\nreturn 0;\nreturn 0;\n}\n\n\n")
        let cpp = try #require(Self.job("#+begin_src C++\nreturn 0;\n#+end_src\n"))
        #expect(cpp.programs == [["g++"]])
        #expect(cpp.script?.contains("echo | g++ -o \"$d/C-bin\"  \"$d/C-src.cpp\"  > /dev/null\n") == true)

        let d = try #require(Self.job("#+begin_src D :flags -O :cmdline x\nwriteln(1);\n#+end_src\n"))
        #expect(d.programs == [["rdmd"]])
        #expect(d.script == "d=$(mktemp -d) || exit 1\ncat > \"$d/C-src.d\"\necho | rdmd -O \"$d/C-src.d\" x\ns=$?\nrm -rf \"$d\"\nexit $s\n")

        let fortran = try #require(Self.job("#+begin_src fortran :flags -O2 :cmdline q\nprint *, 1\n#+end_src\n"))
        #expect(fortran.programs == [["gfortran"]])
        #expect(fortran.script == "d=$(mktemp -d) || exit 1\ncat > \"$d/fortran-src.F90\"\necho | gfortran -o \"$d/fortran-bin\" -O2 \"$d/fortran-src.F90\" > /dev/null\n"
            + "echo | \"$d/fortran-bin\" q\ns=$?\nrm -rf \"$d\"\nexit $s\n")

        // Java's default `:dir .`: compiled in the run's folder, under the package's folders.
        let java = try #require(Self.job("#+begin_src java :classname org.ex.Hello :cmpflag -g :cmdline -ea :cmdargs 1 2\nSystem.out.println(1);\n#+end_src\n"))
        #expect(java.programs == [["javac"], ["java"]])
        #expect(java.directory == ".")
        #expect(java.finish.output)
        #expect(java.script == "mkdir -p 'org/ex/'\ncat > 'org/ex/Hello.java'\necho | { javac -g 'org/ex/Hello.java' && java -cp \"$PWD/\" -ea org.ex.Hello 1 2; }\n")
        #expect(java.input.hasPrefix("package org.ex;\n"))
        let value = try #require(Self.job("#+begin_src java :results value :javac javac -Xlint :java /opt/java -server\nreturn 1;\n#+end_src\n"))
        #expect(value.programs == [["javac"], ["/opt/java"]])
        #expect(value.input.contains("new FileWriter(\"\(Babel.resultFileToken)\")"))
        #expect(value.input.contains("public static Object _main(String[] args) {"))
        #expect(value.script?.contains("echo | { javac -Xlint  'Main.java' && /opt/java -server -cp \"$PWD/\"  Main ; }") == true)

        let clojure = try #require(Self.job("#+begin_src clojure\n(+ 1 2)\n#+end_src\n"))
        #expect(clojure.programs == [["bb", "clojure"]])
        #expect(clojure.input == "(prn (binding [*out* (java.io.StringWriter.)](+ 1 2)))")
        #expect(clojure.script == "d=$(mktemp -d) || exit 1\ncat > \"$d/clojure-cmd-script.clj\"\n"
            + "if command -v bb > /dev/null 2>&1; then echo | bb \"$d/clojure-cmd-script.clj\"; else echo | clojure -M \"$d/clojure-cmd-script.clj\"; fi\n"
            + "s=$?\nrm -rf \"$d\"\nexit $s\n")
        let cli = try #require(Self.job("#+begin_src clojure :backend clojure-cli\n1\n#+end_src\n"))
        #expect(cli.programs == [["clojure"]])
        #expect(cli.script?.contains("echo | clojure -M \"$d/clojure-cmd-script.clj\"\n") == true)
        let cider = "#+begin_src clojure :backend cider\n1\n#+end_src\n"
        guard case .failure(.message(let message)) = Babel.plan(EditContext(revision: 0, text: cider, tree: OrgParser.parse(cider), selection: [2..<2])) else {
            Issue.record("planned cider")
            return
        }
        #expect(message == "The cider backend for clojure needs Emacs; orgstar runs babashka or clojure-cli.")
    }
}
