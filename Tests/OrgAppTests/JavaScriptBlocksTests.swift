import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// js blocks in JavaScriptCore, compared with node and with Emacs running node.
struct JavaScriptBlocksTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil
    static let nodeInstalled = (try? node("1", in: FileManager.default.temporaryDirectory))?.status == 0

    static func plan(_ text: String) throws -> BabelJob {
        let caret = (text as NSString).range(of: "#+begin_src").location + 2
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret])
        guard case .success(let job) = Babel.plan(context) else { throw Babel.Failure.message("not planned: \(text)") }
        return job
    }

    /// `node` reading `input` on standard input, as BabelRunner starts it.
    static func node(_ input: String, in folder: URL) throws -> (stdout: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"]
        process.currentDirectoryURL = folder
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    static let values = [
        "1", "-0", "1.5", "1e21", "NaN", "123n", "true", "null", "undefined", "'abc'", "\"it's\"", "'say \"hi\" it\\'s'",
        "'tab\\there\\n'", "'é 日本'", "'x'.repeat(100)", "Symbol('s')", "[]", "[1, 'a', null, undefined]", "[[1, 2], [3, 4]]",
        "[[[[1]]]]", "{a: {b: {c: {d: 1}}}}", "Array.from({length: 26}, (_, i) => i * 3)", "Array.from({length: 30}, (_, i) => 'item' + i)",
        "Array.from({length: 120}, (_, i) => i)", "[-1, -22, 333, 4, -5, 6, 7, 8, 9, 10, 11]", "[1, , 3]", "new Array(5)",
        "Object.assign([1, 2], {extra: true})", "{'a-b': 1, 2: 3, _x: 4}", "{[Symbol('k')]: 1}", "Object.create(null)",
        "{f() {}, g: () => 1, h: class K {}}", "{longPropertyNameOne: 'value number one', longPropertyNameTwo: 'value number two', three: 3}",
        "(() => { const o = {name: 'x'}; o.self = o; return o; })()", "new Map([['a', 1], ['b', {c: 2}]])", "new Set([1, 'two', [3]])",
        "new (class Point { constructor() { this.x = 1; } })()", "new Date(0)", "/ab+c/gi", "new Uint8Array([1, 2, 3])",
        "new ArrayBuffer(4)", "new Number(3)", "new WeakMap()", "(function () { return arguments; })(1, 2)",
        "Object.defineProperty({}, 'x', {get() { return 1; }, enumerable: true})", "new Proxy(new Proxy([1], {}), {})",
        "{[require('util').inspect.custom]() { return 'custom!'; }}",
        "{data: Array.from({length: 12}, (_, i) => ({n: i, sq: i * i}))}",
    ]

    static let programs = [
        "console.log('%s is %d years', 'Bob', 42)", "console.log('%i %f %j', '42.9px', '1.5e3', {a: [1]})",
        "console.log('%o', [1, {a: 2}])", "console.log('%O', {a: {b: {c: {d: 1}}}})", "console.log('100%% sure', 5)",
        "console.log('%s', [1, [2, [3]]], null, 3n)", "console.log('a', 1, 'b', {c: 1})", "console.log()",
        "console.info('info'); console.error('err'); console.warn('warn')", "console.dir({a: {b: {c: {d: 1}}}}, {depth: 0})",
        "process.stdout.write('a'); process.stdout.write('b')", "const util = require('util'); console.log(util.format('%s=%d', 'x', 5, 'rest'))",
        "const {inspect} = require('node:util'); console.log(inspect({a: [1, {b: {c: {}}}]}, {depth: null, compact: false}))",
        "console.log(require('util').inspect({s: 'a string', l: [1, 2, 3]}, {breakLength: 20, sorted: true}))",
        "setTimeout(() => console.log('b'), 20); setTimeout(() => console.log('a'), 5); setTimeout(() => console.log('c'), 5)",
        "Promise.resolve().then(() => console.log('micro')); setTimeout(() => console.log('macro'), 0); console.log('sync')",
        "let n = 0; const t = setInterval(() => { console.log('tick', ++n); if (n === 3) clearInterval(t); }, 1)",
        "queueMicrotask(() => console.log('q')); (async () => { await null; console.log('awaited'); })(); console.log('s')",
        "console.log('before'); undefinedThing.x; console.log('after')",
        "Promise.resolve().then(() => console.log('not printed')); throw new Error('sync')",
        "setTimeout(() => { throw new TypeError('in timer'); }, 1); setTimeout(() => console.log('not reached'), 5)",
        "var x = 5; console.log(globalThis.x, this === globalThis, typeof module, __filename, global === globalThis)",
        "console.log(JSON.stringify({a: 1, b: [1, 2]}, null, 2), [3, 1, 2].sort(), 0.1 + 0.2)",
        // Every global of node's is here or refused.
        "console.log(Object.getOwnPropertyNames(globalThis).sort().join(' '))",
        "console.log(Object.prototype.toString.call(process), Object.prototype.toString.call(console), typeof require, require.name, require.length)",
        "module.exports = 5; console.log(module.exports, exports, typeof module)",
        "const e = new TypeError('x'); e.stack = 's'; console.log(e.stack, 'stack' in e, Object.keys(e), JSON.stringify(e), String(e))",
        "class Stack { constructor() { this.stack = []; } }; const s = new Stack(); s.stack.push(1); console.log(s.stack, s)",
    ]

    /// The values a block returns, printed by `util.inspect`, and what `console` and timers
    /// print, as node prints them.
    @Test(.enabled(if: oracle && nodeInstalled))
    func matchesNode() async throws {
        let folder = FileManager.default.temporaryDirectory
        let blocks = Self.values.map { "#+begin_src js\nreturn \($0)\n#+end_src\n" }
            + Self.programs.map { "#+begin_src js :results output\n\($0)\n#+end_src\n" }
        for block in blocks {
            let job = try Self.plan(block)
            let theirs = try Self.node(job.input, in: folder)
            let ours = try await JavaScriptBlocks.run(job, directory: folder)
            #expect(ours?.stdout == theirs.stdout && ours?.status == theirs.status, "\(block)\nours: \(ours?.stdout ?? "nil") \(ours?.stderr ?? "")\nnode: \(theirs.stdout)")
        }
    }

    static let emacsCases: [String] = [
        "#+begin_src js :var x=3\nreturn x * 2\n#+end_src\n",
        "#+begin_src js :var x=3 :results output\nconsole.log(x + 1)\n#+end_src\n",
        "#+NAME: tbl\n| 1 | 2 |\n| 3 | 4 |\n\n#+begin_src js :var t=tbl\nreturn t.map(r => r[0] + r[1])\n#+end_src\n",
        "#+NAME: tbl\n| 1 | 2 |\n| 3 | 4 |\n\n#+begin_src js :var t=tbl\nreturn t\n#+end_src\n",
        "#+begin_src js :var s=\"two words\"\nreturn s.length\n#+end_src\n",
        "#+begin_src js :prologue var k = 7; :epilogue return k;\nk = k * 6;\n#+end_src\n",
        "#+begin_src js\nreturn 'abc'\n#+end_src\n",
        "#+begin_src js :results output :epilogue console.log('end')\nconsole.log('body')\n#+end_src\n",
        "#+begin_src js\nreturn {a: 1, b: [1, 2]}\n#+end_src\n",
        "#+begin_src js :results output\nsetTimeout(() => console.log('later'), 10); console.log('now')\n#+end_src\n",
    ]

    /// The results the app inserts, as Emacs inserts them running the block with node.
    @MainActor
    @Test(.enabled(if: oracle && nodeInstalled))
    func resultsMatchEmacs() async throws {
        let folder = try Folder()
        var forms: [String] = []
        var ours: [String] = []
        for text in Self.emacsCases {
            let caret = (text as NSString).range(of: "#+begin_src").location + 2
            let file = try folder.write("b.org", text)
            let session = DocumentSession(recovery: FileRecoveryStore(directory: folder.url.appendingPathComponent(".r")))
            session.open(file.path)
            guard case .external(.babel(let job)) = session.perform(ExecuteSrcBlock(), path: file.path, at: caret, expect: nil) else {
                Issue.record("not planned: \(text)")
                return
            }
            #expect(await session.runBabel(job) == "Code block evaluation complete.")
            ours.append(session.document?.text ?? "")
            let quoted = "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            forms.append("(with-temp-buffer (insert \(quoted)) (org-mode) (goto-char \(caret + 1)) (org-babel-execute-src-block) (princ (concat (buffer-string) \"\\f\")))")
        }
        let emacs = try DailiesTests.emacs("""
            (progn (require 'org) (require 'ob-js)
              (setq org-confirm-babel-evaluate nil org-babel-js-cmd "node" default-directory "\(folder.url.path)/")
              \(forms.joined(separator: "\n")))
            """).split(separator: "\u{0C}", omittingEmptySubsequences: false).map(String.init)
        for (i, text) in Self.emacsCases.enumerated() {
            #expect(ours[i] == emacs[i], "\(text)\nours:\n\(ours[i])\nemacs:\n\(emacs[i])")
        }
    }

    @Test func tableRulesAndModulesFailAsInNode() async throws {
        let folder = FileManager.default.temporaryDirectory
        let rule = try await JavaScriptBlocks.run(Self.plan("#+NAME: t\n| 1 |\n| 2 |\n|---|\n| 3 |\n\n#+begin_src js :var t=t :hlines yes\nreturn t\n#+end_src\n"), directory: folder)
        #expect(rule == BabelOutput(stdout: "", stderr: "ReferenceError: hline is not defined\n", status: 1))
        let fs = try await JavaScriptBlocks.run(Self.plan("#+begin_src js\nreturn require('fs').readFileSync('x')\n#+end_src\n"), directory: folder)
        #expect(fs == BabelOutput(stdout: "", stderr: "Error: Cannot find module 'fs'\n", status: 1))
    }

    @Test func whatNodeAloneHasIsRefused() async throws {
        let folder = FileManager.default.temporaryDirectory
        let module = "top-level await, import or export", stack = "an error's own properties"
        for (header, body, what) in [
            ("", "return new Error('x')", "util.inspect of an Error"), ("", "return Promise.resolve(1)", "util.inspect of a Promise"),
            ("", "return Buffer.from('a')", "Buffer"), ("", "return process.env.HOME", "process.env"), ("", "console.table([1])", "console.table"),
            (" :results output", "console.log(await Promise.resolve(5))", module), (" :results output", "for await (const x of [1]) console.log(x)", module),
            (" :results output", "import util from 'util'; console.log(util.format('%d', 3))", module),
            (" :results output", "console.log(import.meta.url)", module), (" :results output", "export const x = 1", module),
            ("", "return new Error('x').stack", "Error.stack"), (" :results output", "try { null.x } catch (e) { console.log(e.stack) }", "Error.stack"),
            ("", "return Error.stackTraceLimit", "Error.stackTraceLimit"), ("", "const o = {}; Error.captureStackTrace(o); return o", "Error.captureStackTrace"),
            ("", "return Object.getOwnPropertyNames(new Error('x'))", stack), ("", "return Reflect.ownKeys(new RangeError('x'))", stack),
            ("", "return new Error('x').hasOwnProperty('stack')", stack), ("", "return Object.hasOwn(new Error('x'), 'stack')", stack),
            ("", "return require('util').inspect(Error.prototype, {showHidden: true})", stack),
            ("", "return typeof Temporal", "Temporal"), ("", "return new SharedArrayBuffer(2)", "SharedArrayBuffer"),
            ("", "return typeof DOMException", "DOMException"), ("", "return typeof ReadableStream", "ReadableStream"),
            ("", "return 'env' in process", "process.env"), ("", "return Object.keys(console).length", "the members of console"),
            ("", "return Object.getPrototypeOf(process)", "the prototype of process"), ("", "process.exitCode = 1", "process.exitCode"),
            ("", "return process.toString()", "process.toString"), ("", "return typeof require.resolve", "require.resolve"),
            ("", "return require.cache", "require.cache"), ("", "return module.id", "module.id"), ("", "return typeof module.paths", "module.paths"),
            (" :results output", "console.log(globalThis)", "util.inspect of the global object"), ("", "return this", "util.inspect of the global object"),
            ("", "return require", "util.inspect of require"), ("", "return module", "util.inspect of module"),
        ] {
            await #expect(throws: Babel.Failure.message("This block uses \(what), which runs only in node."), "\(body)") {
                try await JavaScriptBlocks.run(Self.plan("#+begin_src js\(header)\n\(body)\n#+end_src\n"), directory: folder)
            }
        }
        // A syntax error that isn't a module's is reported, as node reports it.
        #expect(try await JavaScriptBlocks.run(Self.plan("#+begin_src js :results output\nconsole.log(1); return 2\n#+end_src\n"), directory: folder)?.status == 1)
        #expect(try await JavaScriptBlocks.run(Self.plan("#+begin_src python\n1\n#+end_src\n"), directory: folder) == nil)
        await #expect(throws: Babel.Failure.message("No folder \(folder.appendingPathComponent("nowhere").path) for :dir.")) {
            try await JavaScriptBlocks.run(Self.plan("#+begin_src js :dir nowhere\nreturn 1\n#+end_src\n"), directory: folder)
        }
    }

    @Test func sessionsKeepTheirContext() async throws {
        let folder = try Folder()
        func run(_ header: String, _ body: String) async throws -> BabelOutput? {
            try await JavaScriptBlocks.run(Self.plan("#+begin_src js :session work\(header)\n\(body)\n#+end_src\n"), directory: folder.url)
        }
        #expect(try await run("", "var x = 41; let y = 2")?.resultFile == "undefined")
        #expect(try await run("", "x + y")?.resultFile == "43")
        #expect(try await run("", "throw new Error('boom')") == BabelOutput(stdout: "", stderr: "Error: boom\n", status: 1))
        #expect(try await run("", "[x, {y}]")?.resultFile == "[ 41, { y: 2 } ]")
        #expect(try await run(" :results output", "console.log(x); x") == BabelOutput(stdout: "41\n"))
        // node's session returns before a timer runs, and it prints later; a block that leaves one is refused.
        await #expect(throws: Babel.Failure.message("This block uses a timer in a session, which runs only in node.")) {
            try await run(" :results output", "var z = 1; setInterval(() => console.log('tick'), 10)")
        }
        await #expect(throws: Babel.Failure.message("This block uses a timer in a session, which runs only in node.")) {
            try await run("", "setTimeout(() => {}, 1).unref(); 2")
        }
        #expect(try await run("", "const t = setTimeout(() => {}, 1); clearTimeout(t); z")?.resultFile == "1")
        // An error while printing the value is reported, and there is no result.
        let thrown = try await run("", "({[Symbol.for('nodejs.util.inspect.custom')]() { throw new TypeError('boom') }})")
        #expect(thrown == BabelOutput(stdout: "", stderr: "TypeError: boom\n", status: 1))
        let other = try Folder()
        #expect(try await JavaScriptBlocks.run(Self.plan("#+begin_src js :session work\ntypeof x\n#+end_src\n"), directory: other.url)?.resultFile == "'undefined'")
    }

    @Test func cancelAndTimeoutEndTheRun() async throws {
        let folder = FileManager.default.temporaryDirectory
        // Spins for seconds, as an endless loop would, but ends so the test leaves no thread busy.
        let spin = try Self.plan("#+begin_src js\nconst end = Date.now() + 3000; while (Date.now() < end) {}\n#+end_src\n")
        let start = ContinuousClock.now
        let task = Task { try await JavaScriptBlocks.run(spin, directory: folder) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: JavaScriptBlocks.Stopped.self) { try await JavaScriptBlocks.run(spin, directory: folder, timeout: .milliseconds(100)) }
        #expect(ContinuousClock.now - start < .seconds(2))
        let interval = try Self.plan("#+begin_src js :results output\nsetInterval(() => {}, 10)\n#+end_src\n")
        await #expect(throws: JavaScriptBlocks.Stopped.self) { try await JavaScriptBlocks.run(interval, directory: folder, timeout: .milliseconds(100)) }
    }
}
