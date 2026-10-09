import Foundation
import Testing
import OrgCore
@testable import OrgApp

struct BabelSessionStateTests {
    func run(_ text: String, in folder: URL) async throws -> String {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { Issue.record("not planned: \(text)"); return "" }
        let output = try await BabelRunner.run(job, fileDirectory: folder)
        guard case .success(let edits) = Babel.finish(job, output: output, text: text) else { return "" }
        let new = edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
        return String(new.dropFirst(text.count))
    }

    @Test func sessionsKeepState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            BabelSessions.shared.stopAll()
            try? FileManager.default.removeItem(at: folder)
        }
        _ = try await run("#+begin_src sh :session s1\nx=5; cd /tmp\n#+end_src\n", in: folder)
        #expect(try await run("#+begin_src sh :session s1 :results output\necho $x\n#+end_src\n", in: folder) == "\n#+RESULTS:\n: 5\n")
        #expect(try await run("#+begin_src sh :session other :results output\necho \"[$x]\"\n#+end_src\n", in: folder) == "\n#+RESULTS:\n: []\n")
        _ = try await run("#+begin_src python :session py :results output\na = 2\nprint('set')\n#+end_src\n", in: folder)
        #expect(try await run("#+begin_src python :session py\na * 3\n#+end_src\n", in: folder) == "\n#+RESULTS:\n: 6\n")
        #expect(try await run("#+begin_src python :session py :results output\nprint(a + 1)\n#+end_src\n", in: folder) == "\n#+RESULTS:\n: 3\n")
        _ = try await run("#+begin_src python :session py :results output\nraise ValueError('x')\n#+end_src\n", in: folder)
        #expect(try await run("#+begin_src python :session py\n[a, a]\n#+end_src\n", in: folder) == "\n#+RESULTS:\n| 2 | 2 |\n")
    }
}

struct BabelRunnerTests {
    @Test func refusesWithoutTheCompiler() async throws {
        for (text, programs, message) in [
            ("#+begin_src D\nwriteln(1);\n#+end_src\n", ["rdmd"], "rdmd isn't installed, so D blocks can't run."),
            ("#+begin_src clojure\n1\n#+end_src\n", ["bb", "clojure"], "Neither bb nor clojure is installed, so clojure blocks can't run."),
        ] where !programs.contains(where: BabelRunner.installed) {
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
            guard case .success(let job) = Babel.plan(context) else {
                Issue.record("not planned: \(text)")
                continue
            }
            do {
                _ = try await BabelRunner.run(job, fileDirectory: FileManager.default.temporaryDirectory)
                Issue.record("ran: \(text)")
            } catch let failure as BabelRunner.Failure {
                #expect(failure.description == message)
            }
        }
    }

    @Test(.enabled(if: BabelRunner.installed("gcc")))
    func compilesAndRunsC() async throws {
        let text = "#+begin_src C :includes <stdio.h>\nprintf(\"%d\\n\", 6 * 7);\n#+end_src\n"
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else {
            Issue.record("not planned")
            return
        }
        let output = try await BabelRunner.run(job, fileDirectory: FileManager.default.temporaryDirectory)
        #expect(output.stdout == "42\n")
        #expect(output.problem == nil)
    }
}
