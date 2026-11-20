import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp
@testable import OrgPrograms

/// Runs each test with `Programs` as the session's runner, scoped to the test's task so
/// suites without one are unaffected.
struct WithPrograms: SuiteTrait, TestTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await DocumentSession.$scopedPrograms.withValue(Programs()) { try await function() }
    }
}

extension Trait where Self == WithPrograms {
    static var programs: Self { WithPrograms() }
}

@MainActor
@Suite(.programs)
struct EmacsFallbackTests {
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func recalculatesTablesNativeCodeCannot() async throws {
        let notes = try Folder()
        let file = try notes.write("t.org", "* Prices\n| item | n | twice |\n|------+---+-------|\n| x | a | |\n| y | 2 | |\n#+TBLFM: $3=$2*2\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(TableRecalculate(all: true), path: file.path, at: 50, expect: nil)
        guard case .external(.emacsTable(let table, let point, let form, let reason, let lisp)) = step else {
            Issue.record("\(step)")
            return
        }
        #expect(reason == "non-numeric field a")
        #expect(!lisp)
        let message = await session.recalculateInEmacs(table: table, point: point, form: form)
        #expect(message == "Recalculated in Emacs")
        #expect(session.document?.text == "* Prices\n| item | n | twice |\n|------+---+-------|\n| x    | a | 2 a   |\n| y    | 2 | 4     |\n#+TBLFM: $3=$2*2\n")
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func cancelingARecalculationLeavesTheTable() async throws {
        let notes = try Folder()
        let text = "| n | twice |\n|---+-------|\n| a |       |\n#+TBLFM: $2=$1*2\n"
        let file = try notes.write("t.org", text)
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(TableRecalculate(all: true), path: file.path, at: 2, expect: nil)
        guard case .external(.emacsTable(let table, let point, let form, _, _)) = step else {
            Issue.record("\(step)")
            return
        }
        let task = Task { await session.recalculateInEmacs(table: table, point: point, form: form) }
        task.cancel()
        #expect(await task.value == "Recalculation canceled")
        #expect(session.document?.text == text)
    }
}

@MainActor
@Suite(.programs)
struct BabelSessionTests {
    @Test func runsBlocksAndWritesResults() async throws {
        let notes = try Folder()
        let file = try notes.write("b.org", "#+begin_src sh\necho answer\necho \"$((6 * 7))\"\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let step = session.perform(ExecuteSrcBlock(), path: file.path, at: 3, expect: nil)
        guard case .external(.babel(let job)) = step else {
            Issue.record("\(step)")
            return
        }
        #expect(await session.runBabel(job) == "Code block evaluation complete.")
        // A column that is half numbers is right-aligned, as org-table-align does.
        #expect(session.document?.text == "#+begin_src sh\necho answer\necho \"$((6 * 7))\"\n#+end_src\n\n#+RESULTS:\n| answer |\n|     42 |\n")
    }
}

@MainActor
@Suite(.programs)
struct BabelErrorTests {
    func job(_ session: DocumentSession, _ path: String) throws -> BabelJob {
        guard case .external(.babel(let job)) = session.perform(ExecuteSrcBlock(), path: path, at: 3, expect: nil) else {
            throw CancellationError()
        }
        return job
    }

    /// Like `org-babel-eval`: the results go in, and the error output and status are shown.
    @Test func reportsErrorsAndStillInsertsResults() async throws {
        let notes = try Folder()
        let file = try notes.write("e.org", "#+begin_src sh\necho out\necho oops >&2\nexit 3\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        #expect(await session.runBabel(try job(session, file.path)) == "Exited with status 3: oops")
        #expect(session.document?.text.hasSuffix("#+RESULTS:\n: out\n") == true)
    }

    @Test func cancelsARunningBlock() async throws {
        let notes = try Folder()
        let file = try notes.write("s.org", "#+begin_src sh\nsleep 20\necho late\n#+end_src\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        let start = ContinuousClock.now
        var message: String?
        session.startBabel(try job(session, file.path)) { message = $0 }
        #expect(session.isRunningBabel)
        try await Task.sleep(for: .milliseconds(200))
        session.cancelBabel()
        while message == nil, ContinuousClock.now - start < .seconds(5) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(message == "Code block canceled.")
        #expect(!session.isRunningBabel)
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(session.document?.text.contains("#+RESULTS:") == false)
    }
}

struct EmacsExportTests {
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportsBesideTheFile() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "#+TITLE: On disk\n")
        // The buffer's text is exported, not the file's.
        let written = try await EmacsRunner.export(text: "#+TITLE: In the buffer\n\n* Heading\nBody.\n", path: file.path, function: "org-ascii-export-to-ascii")
        #expect(URL(fileURLWithPath: written).lastPathComponent == "doc.txt")
        let text = try String(contentsOfFile: written, encoding: .utf8)
        #expect(text.uppercased().contains("IN THE BUFFER") && text.contains("Body."), "\(text)")
        #expect(try String(contentsOf: file, encoding: .utf8) == "#+TITLE: On disk\n")
    }

    /// The dispatcher's `C-s` and `C-b`: the subtree at point alone, its EXPORT_FILE_NAME used.
    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportsTheSubtreeBodyOnly() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let text = "#+TITLE: Doc\n* Ünï\nFirst.\n* Second\n:PROPERTIES:\n:EXPORT_FILE_NAME: second\n:END:\nOnly this.\n"
        let point = (text as NSString).substring(to: (text as NSString).range(of: "Only").location).unicodeScalars.count + 1
        let written = try await EmacsRunner.export(text: text, path: file.path, function: "org-ascii-export-to-ascii", subtree: point, bodyOnly: true)
        #expect(URL(fileURLWithPath: written).lastPathComponent == "second.txt")
        let out = try String(contentsOfFile: written, encoding: .utf8)
        #expect(out.contains("Only this.") && !out.contains("First.") && !out.uppercased().contains("DOC"), "\(out)")
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func exportUsesBabelPath() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let function = #"(lambda () (with-temp-file "path.txt" (insert (getenv "PATH"))) "path.txt")"#
        let written = try await EmacsRunner.export(text: "", path: file.path, function: function)
        #expect(try String(contentsOfFile: written, encoding: .utf8) == BabelRunner.environment["PATH"])
    }

    @Test(.enabled(if: EmacsRunner.executable() != nil && ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func cancellingStopsTheExport() async throws {
        let notes = try Folder()
        let file = try notes.write("doc.org", "")
        let pidFile = notes.url.appendingPathComponent("pid")
        let function = #"(lambda () (with-temp-file "pid" (insert (number-to-string (emacs-pid)))) (sleep-for 60) "x")"#
        let export = Task { try await EmacsRunner.export(text: "", path: file.path, function: function) }
        var pid: pid_t?
        for _ in 0..<200 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0) }
        }
        let started = try #require(pid)
        export.cancel()
        await #expect(throws: CancellationError.self) { try await export.value }
        var alive = true
        for _ in 0..<100 where alive {
            alive = kill(started, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive)
    }
}

/// js runs in JavaScriptCore when its interpreter isn't installed, and in node when it is.
struct JavaScriptFallbackTests {
    func run(_ text: String) async throws -> BabelOutput {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned") }
        return try await Programs().runBabel(job, fileDirectory: FileManager.default.temporaryDirectory)
    }

    @Test func runsWithoutTheInterpreter() async throws {
        #expect(try await run("#+begin_src js :cmd no-such-node\nreturn [1, 2]\n#+end_src\n").stdout == "[ 1, 2 ]")
        #expect(try await run("#+begin_src js :cmd no-such-node :session s\n6 * 7\n#+end_src\n").resultFile == "42")
    }

    /// A `:cmd` with arguments isn't run in JavaScriptCore, which can't take node's options.
    @Test func leavesACommandWithArgumentsToTheRunner() async throws {
        let error = await #expect(throws: BabelRunner.Failure.self) {
            try await run("#+begin_src js :cmd \"no-such-node --no-warnings\" :results output\nconsole.log(1)\n#+end_src\n")
        }
        #expect(error?.description == "no-such-node --no-warnings isn't installed.")
    }

    @Test(.enabled(if: BabelRunner.installed("node")))
    func usesNodeWhenInstalled() async throws {
        #expect(try await run("#+begin_src js :results output\nconsole.log(typeof require('fs').readFileSync)\n#+end_src\n").stdout == "function\n")
    }
}

/// Emacs Lisp runs in `Elisp` when Emacs isn't installed.
struct EmacsLispFallbackTests {
    func run(_ text: String) async throws -> BabelOutput {
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [2..<2])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned") }
        return try await Programs(emacs: { nil }).runBabel(job, fileDirectory: FileManager.default.temporaryDirectory)
    }

    @Test func runsWithoutEmacs() async throws {
        #expect(try await run("#+begin_src emacs-lisp\n(cl-loop for i from 1 to 4 sum i)\n#+end_src\n").stdout.contains("\"s\":\"10\""))
    }

    @Test func refusesWhatOnlyEmacsRuns() async throws {
        let error = await #expect(throws: BabelRunner.Failure.self) {
            try await run("#+begin_src emacs-lisp\n(with-temp-buffer (insert \"x\") (buffer-string))\n#+end_src\n")
        }
        #expect(error?.description == "This block uses Emacs Lisp that runs only in Emacs, and Emacs isn't installed.")
    }
}
