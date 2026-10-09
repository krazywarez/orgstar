import CryptoKit
import Foundation

// Babel (ob-core.el, ob-shell.el, ob-python.el, ob-emacs-lisp.el, Org 9.8.7): executing a src
// block is planned here, run by the platform, and finished here. The plan resolves header
// arguments and refuses anything that would make the run differ from Emacs's; the finish turns
// the output into a result the way `org-babel-insert-result` writes it.

/// A src block run for the platform to carry out.
public struct BabelJob: Sendable, Equatable {
    public enum Runner: Sendable, Equatable {
        /// An interpreter reading the program on standard input.
        case process(executable: String, arguments: [String])
        /// `emacs --batch` loading `input` as a script.
        case emacs
        /// A long-running interpreter named by `:session`: a shell gets `input` as commands, Python
        /// runs `input` as a program in its globals.
        case session(name: String, executable: String, python: Bool)
    }

    public let language: String
    public let runner: Runner
    /// Standard input, or the Emacs script. `Babel.resultFileToken` stands for a file the runner
    /// creates; its contents come back as `BabelOutput.resultFile`.
    public let input: String
    /// `:dir`, relative to the file's folder; nil for the folder itself.
    public let directory: String?
    /// The block as it was planned, to find it again when the run ends.
    public let block: Range<Int>
    public let blockText: String
    /// Asks every time (`:eval query`) rather than trusting by content.
    public let alwaysAsk: Bool
    public let finish: Finish
    /// A named block a `:var` refers to: run it first, then `Babel.resume` with its output.
    public var needs: [Need] = []
    /// With `needs`: the text of every block the run may execute, the one asked about and
    /// those its references reach. A later job for a block not among them is refused.
    public internal(set) var approved: [String] = []
    /// Values of the references resolved so far, and how to plan again.
    var resolved: [String: Babel.VarValue] = [:]
    var caret = 0
    var options = Babel.Options()
    /// A script for the runner to write to an executable file, for `Babel.scriptFileToken`.
    public internal(set) var script: String?
    /// Programs the run needs: for each list, one of them on PATH.
    public internal(set) var programs: [[String]] = []
    /// An Emacs Lisp block's form, for `Babel.evaluateNatively`.
    public internal(set) var lispForm: String?
    /// A Lisp header value couldn't be evaluated without the file's path: plan again with
    /// `Babel.replan` before running.
    public internal(set) var needsFile = false

    public struct Need: Sendable, Equatable {
        /// The `:var` value, `name` or `name(args)`.
        public let reference: String
        public let job: BabelJob
    }

    public struct Finish: Sendable, Equatable {
        /// `compiled`: C, C++, D, Java, Fortran and Clojure, by `language`.
        enum Kind: Sendable, Equatable { case shell(valueIsExitStatus: Bool), python, generic, emacsLisp, compiled }
        let kind: Kind
        var language = ""
        public internal(set) var params: [String]
        let output: Bool
        let wrap: String?
        let name: String?
        /// An inline block: the result goes after it, in `{{{results(…)}}}`.
        var inline = false
        /// `:file` (under `:output-dir`) with `:results file`, and `:file-desc`.
        var file: String?
        var fileDescription: String?
        /// The program writes `file` itself, as graphics languages do.
        var writesFile = false
        /// `:cache yes`: the hash for the `#+RESULTS[…]:` line.
        var hash: String?
        /// Column and row names a table `:var` gave up, put back on a table result
        /// (`org-babel-reassemble-table`).
        var colnames: [String]?
        var rownames: [String]?
    }
}

public struct BabelOutput: Sendable, Equatable {
    public var stdout: String
    public var resultFile: String?
    /// What the program wrote to standard error, and its exit status: Emacs shows them in
    /// `*Org-Babel Error Output*` and still inserts the results.
    public var stderr: String
    public var status: Int32
    public init(stdout: String, resultFile: String? = nil, stderr: String = "", status: Int32 = 0) {
        self.stdout = stdout
        self.resultFile = resultFile
        self.stderr = stderr
        self.status = status
    }

    /// A line for the message area when the program failed or complained, else nil.
    public var problem: String? {
        let first = stderr.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
        switch (status, first) {
        case (0, nil): return nil
        case (0, let line?): return line
        case (let code, nil): return "Exited with status \(code)"
        case (let code, let line?): return "Exited with status \(code): \(line)"
        }
    }
}

public enum Babel {
    public static let resultFileToken = "__ORGSTAR_RESULT_FILE__"
    /// Stands, in a job's arguments, for the executable file the runner writes `job.script` to.
    public static let scriptFileToken = "__ORGSTAR_SCRIPT_FILE__"
    static let shells: Set<String> = ["sh", "bash", "zsh", "shell", "fish", "ksh", "dash", "ash", "csh", "mksh", "posh"]
    static let generic: [String: (String, [String])] = [
        "ruby": ("ruby", []), "js": ("node", []), "javascript": ("node", []), "R": ("Rscript", ["-"]),
        "awk": ("awk", ["-f", "/dev/stdin"]),
    ]

    public struct Options: Sendable, Equatable {
        public var python = "python3"
        /// `shell-file-name`, from `SHELL` as Emacs sets it: runs blocks in the `shell` language
        /// and chooses how variables are written in the `:cache` hash.
        public var shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        /// The file the block is in, for Lisp header values that use it.
        public var file: String?
        public init() {}
    }

    // MARK: - Planning

    /// The run for the src block at the caret, or why it can't run.
    public static func plan(_ context: EditContext, options: Options = Options()) -> Result<BabelJob, Failure> {
        plan(context, options: options, resolved: [:])
    }

    /// Plans the block again with the value of the block `job` needed: the output of
    /// `need.job`, as `org-babel-ref-resolve` reads it.
    public static func resume(_ job: BabelJob, need: BabelJob.Need, output: BabelOutput, text: String, tree: OrgTree) -> Result<BabelJob, Failure> {
        var resolved = job.resolved
        resolved[need.reference] = varValue(need.job.finish, output)
        let context = EditContext(revision: 0, text: text, tree: tree, selection: [job.caret..<job.caret])
        return plan(context, options: job.options, resolved: resolved)
    }

    /// Plans `job`'s block again knowing the file it is in.
    public static func replan(_ job: BabelJob, file: String, text: String, tree: OrgTree) -> Result<BabelJob, Failure> {
        var options = job.options
        options.file = file
        let context = EditContext(revision: 0, text: text, tree: tree, selection: [job.caret..<job.caret])
        return plan(context, options: options, resolved: job.resolved)
    }

    static func plan(_ context: EditContext, options: Options, resolved: [String: VarValue]) -> Result<BabelJob, Failure> {
        let text = context.text
        let ns = text as NSString
        let model = DocumentModel(tree: context.tree)
        let refs = References(resolved: resolved, options: options)
        func located(_ result: Result<BabelJob, Failure>) -> Result<BabelJob, Failure> {
            result.map { job in
                var job = job
                (job.caret, job.resolved, job.options) = (context.caret, resolved, options)
                return job
            }
        }
        do {
            if let block = model.srcBlocks.first(where: { $0.range.contains(context.caret) || $0.range.upperBound == context.caret }) {
                return located(plan(block, params: try Params(block: block, model: model, text: ns), model: model, text: ns, options: options,
                                    location: block.range, name: block.name, refs: refs))
            }
            if let call = try callAt(context.caret, model: model, text: ns) {
                return located(plan(call.block, params: call.params, model: model, text: ns, options: options, location: call.location, name: call.name, refs: refs))
            }
            if let call = try inlineCallAt(context.caret, tree: context.tree, model: model, text: ns) {
                return located(plan(call.block, params: call.params, model: model, text: ns, options: options, location: call.location, name: nil, inline: true, refs: refs))
            }
            if let inline = try inlineAt(context.caret, tree: context.tree, model: model, text: ns) {
                return located(plan(inline.block, params: inline.params, model: model, text: ns, options: options, location: inline.block.range, name: nil, inline: true, refs: refs))
            }
        } catch let error as Failure {
            return .failure(error)
        } catch {
            return .failure(.message("\(error)"))
        }
        return .failure(.message("Not in a source block"))
    }

    /// The `#+CALL:` line at `offset`: the block it names, with the call's inside header, its
    /// arguments as `:var` and its end header over the block's own (`org-babel-lob-get-info`).
    static func callAt(_ offset: Int, model: DocumentModel, text: NSString) throws -> (block: SrcBlockInfo, params: Params, location: Range<Int>, name: String?)? {
        let lineRange = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0))
        let line = text.substring(with: lineRange)
        guard let m = line.firstMatch(of: #/(?i)^[ \t]*#\+CALL:[ \t]*([^\s(\[]+)(?:\[([^\]]*)\])?\((.*?)\)[ \t]*(.*?)[ \t]*\n?$/#) else { return nil }
        let name = String(m.1)
        guard let block = model.srcBlocks.first(where: { $0.name == name }) else { throw Failure.message("Reference '\(name)' not found in this buffer") }
        var extra = [lobDefaults] + callProperties(block, at: lineRange.location, model: model)
        if let inside = m.2 { extra.append(Params.parse(String(inside))) }
        extra.append(splitArguments(String(m.3)).map { (":var", $0) })
        if !m.4.isEmpty { extra.append(Params.parse(String(m.4))) }
        // The call's own #+NAME names its results.
        var callName: String?
        if lineRange.location > 0 {
            let previous = text.substring(with: text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0)))
            callName = previous.firstMatch(of: #/(?i)^[ \t]*#\+NAME:[ \t]*(\S+)/#).map { String($0.1) }
        }
        let location = lineRange.location..<NSMaxRange(lineRange)
        return (block, try Params(block: block, model: model, text: text, extra: extra), location, callName)
    }

    /// The inline `call_NAME[INSIDE](ARGS)[END]` at `offset`: like `#+CALL`, with the result
    /// after the call.
    static func inlineCallAt(_ offset: Int, tree: OrgTree, model: DocumentModel, text: NSString) throws -> (block: SrcBlockInfo, params: Params, location: Range<Int>)? {
        var node = tree.root
        var found: SyntaxNode?
        while let child = node.child(containing: offset) {
            if child.kind == .inlineBabelCall { found = child }
            node = child
        }
        guard let object = found, let m = object.text.firstMatch(of: /^call_([^()\[\]\s]+)(?:\[([^\]]*)\])?\((.*?)\)(?:\[([^\]]*)\])?$/) else { return nil }
        let name = String(m.1)
        guard let block = model.srcBlocks.first(where: { $0.name == name }) else { throw Failure.message("Reference '\(name)' not found in this buffer") }
        var extra = [lobDefaults] + callProperties(block, at: object.range.lowerBound, model: model)
        if let inside = m.2 { extra.append(Params.parse(String(inside))) }
        extra.append(splitArguments(String(m.3)).map { (":var", $0) })
        if let end = m.4 { extra.append(Params.parse(String(end))) }
        return (block, try Params(block: block, model: model, text: text, extra: extra), object.range)
    }

    /// The `header-args` properties where a call is, in the called block's language, which
    /// `org-babel-lob-get-info` puts after `lobDefaults`.
    static func callProperties(_ block: SrcBlockInfo, at location: Int, model: DocumentModel) -> [[(String, String)]] {
        let heading = model.headings.lastIndex { $0.headingRange.lowerBound <= location }
        return Params.propertyLayers(language: block.language ?? "", heading: heading, model: model)
    }

    /// `org-babel-default-lob-header-args`, over the called block's own header arguments.
    static let lobDefaults = [(":exports", "results")]

    /// `org-babel-default-header-args:LANG` in Org 9.8.7 other than `:exports`.
    static let languageDefaults = ["java": [(":results", "output"), (":dir", ".")]]

    /// `:exports` from the language's `org-babel-default-header-args:LANG` in Org 9.8.7.
    static let languageExports = ["dot": "results", "plantuml": "results", "ditaa": "results", "gnuplot": "results",
                                  "latex": "results", "lilypond": "results"]

    /// What export shows of the src block, `#+CALL:` line, inline call or inline src block
    /// starting at `offset` (`org-babel-exp-process-buffer`): `code`, `results`, `both` or
    /// `none`, from the header arguments as evaluation resolves them. Calls never show code.
    /// Nil when nothing there runs.
    public static func exports(at offset: Int, tree: OrgTree, model: DocumentModel, text: NSString) -> String? {
        func value(_ params: Params?, language: String?) -> String {
            (params?.single[":exports"] ?? language.flatMap { languageExports[$0] } ?? "code").lowercased()
        }
        if let block = model.srcBlocks.first(where: { $0.range.lowerBound == offset }) {
            return value(try? Params(block: block, model: model, text: text), language: block.language)
        }
        let line = text.substring(with: text.lineRange(for: NSRange(location: min(offset, text.length), length: 0)))
        let call: Params?
        if line.range(of: "(?i)^[ \\t]*#\\+CALL:", options: .regularExpression) != nil {
            call = (try? callAt(offset, model: model, text: text))?.params
        } else if tree.root.descendants().contains(where: { $0.kind == .inlineBabelCall && $0.range.lowerBound == offset }) {
            // `org-babel-remove-result` only takes away `#+RESULTS:`, so an inline call's
            // `{{{results(...)}}}` stays whatever `:exports` says.
            return "results"
        } else if let inline = try? inlineAt(offset, tree: tree, model: model, text: text), inline.block.range.lowerBound == offset {
            return value(inline.params, language: inline.block.language)
        } else {
            return nil
        }
        // `org-babel-exp-code` for a call is `org-babel-exp-call-line-template`, empty.
        switch call?.single[":exports"]?.lowercased() ?? "results" {
        case "both", "results": return "results"
        default: return "none"
        }
    }

    /// Call arguments split on commas outside quotes and parentheses.
    static func splitArguments(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        for c in s {
            if c == "\"" { quoted.toggle() }
            if !quoted, c == "(" { depth += 1 }
            if !quoted, c == ")" { depth -= 1 }
            if c == ",", !quoted, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The inline `src_LANG[HEADERS]{BODY}` at `offset`.
    static func inlineAt(_ offset: Int, tree: OrgTree, model: DocumentModel, text: NSString) throws -> (block: SrcBlockInfo, params: Params)? {
        var node = tree.root
        var found: SyntaxNode?
        while let child = node.child(containing: offset) {
            if child.kind == .inlineSourceBlock { found = child }
            node = child
        }
        guard let object = found, let m = object.text.firstMatch(of: /^src_([^\s\[{]+)(?:\[([^\]]*)\])?\{(.*)\}$/) else { return nil }
        let heading = model.headings.lastIndex { $0.headingRange.lowerBound <= object.range.lowerBound }
        let block = SrcBlockInfo(range: object.range, heading: heading, name: nil, language: String(m.1), switches: [], body: String(m.3), headerArguments: [:])
        let extra = m.2.map { [Params.parse(String($0))] } ?? []
        return (block, try Params(block: block, model: model, text: text, defaults: [(":exports", "results"), (":hlines", "yes")], extra: extra, inline: true))
    }

    /// What `:var` references resolve to while planning.
    struct References {
        var resolved: [String: VarValue]
        var options: Options
        /// Blocks being planned for a reference, to stop cycles.
        var visiting: Set<String> = []
    }

    /// A reference to a block that has to run first.
    struct Needed: Error {
        let need: BabelJob.Need
    }

    static func plan(_ block: SrcBlockInfo, params: Params, model: DocumentModel, text ns: NSString, options: Options,
                     location: Range<Int>, name: String?, inline: Bool = false, refs: References? = nil, useCache: Bool = true) -> Result<BabelJob, Failure> {
        var evaluated = params
        evaluated.evaluateLisp(file: options.file)
        let needsFile = options.file == nil && evaluated.lisp.contains { evaluated.evaluated[$0] == nil }
        return planBlock(block, params: params, model: model, text: ns, options: options, location: location, name: name, inline: inline,
                         refs: refs, useCache: useCache).map { job in
            var job = job
            job.needsFile = needsFile
            return job
        }
    }

    static func planBlock(_ block: SrcBlockInfo, params: Params, model: DocumentModel, text ns: NSString, options: Options,
                          location: Range<Int>, name: String?, inline: Bool, refs: References?, useCache: Bool) -> Result<BabelJob, Failure> {
        let refs = refs ?? References(resolved: [:], options: options)
        var params = params
        params.evaluateLisp(file: options.file)
        let needsFile = options.file == nil && params.lisp.contains { params.evaluated[$0] == nil }
        guard let language = block.language else { return .failure(.message("This block has no language")) }
        let eval = params.single[":eval"]?.lowercased()
        if eval == "never" || eval == "no" {
            return .failure(.message("Evaluation of this \(language) code block\(block.name.map { " (\($0)) " } ?? " ")is disabled."))
        }
        let compiled = expandedLanguages.contains(language)
        if params.single[":cmdline"] != nil, !["dot", "plantuml", "mermaid"].contains(language), !shells.contains(language), !compiled {
            return .failure(.message(":cmdline isn't supported for \(language) yet; nothing was run."))
        }
        for key in [":prologue", ":epilogue", ":post", ":stdin", ":shebang"] where params.single[key] != nil
            && !(shells.contains(language) && [":stdin", ":shebang"].contains(key)) && !(compiled && [":prologue", ":epilogue"].contains(key)) {
            return .failure(.message("\(key) isn't supported yet; nothing was run."))
        }
        // The compiled languages' `org-babel-execute:` ignore `:session`.
        let session = compiled ? nil : params.single[":session"].flatMap { $0 == "none" ? nil : ($0.isEmpty ? "*\(language)*" : $0) }
        if session != nil, !shells.contains(language), language != "python" {
            return .failure(.message(":session isn't supported for \(language) yet; nothing was run."))
        }
        var body = normalizedBody(block)
        if nowebEvaluates(params.single[":noweb"]) {
            do {
                body = try expandNoweb(block, params: params, model: model, text: ns)
            } catch let error as Failure {
                return .failure(error)
            } catch {
                return .failure(.message("\(error)"))
            }
        }
        let output = params.results.contains("output")
        let file = params.single[":file"].map { name in
            params.single[":output-dir"].map { $0.hasSuffix("/") ? $0 + name : $0 + "/" + name } ?? name
        }
        let toFile = params.results.contains("file")
        var hash: String?
        var tables = Tables()
        let finishBase = { (kind: BabelJob.Finish.Kind) in
            BabelJob.Finish(kind: kind, language: language, params: params.results, output: output, wrap: params.wrap, name: name, inline: inline,
                            file: toFile ? file : nil, fileDescription: params.single[":file-desc"], hash: hash,
                            colnames: tables.picked(tables.colnames, ":colnames", params), rownames: tables.picked(tables.rownames, ":rownames", params))
        }
        let vars: [(String, VarValue)]
        var stdin: VarValue?
        do {
            tables = try disassemble(params.vars.map { ($0.name, try resolve($0.value, model: model, text: ns, refs: refs)) }, params: params)
            vars = tables.vars
            stdin = try params.single[":stdin"].map { try resolve($0, model: model, text: ns, refs: refs) }
        } catch let needed as Needed {
            // Asked about once, with every block the references reach; asked every time when
            // any of them has `:eval query`.
            let reached = referencedBlocks(params, model: model, text: ns, seen: [])
            let texts = [ns.substring(with: NSRange(location))] + reached.map { ns.substring(with: NSRange($0.range)) }
            let query = eval == "query" || reached.contains { (try? Params(block: $0, model: model, text: ns))?.single[":eval"]?.lowercased() == "query" }
            var job = BabelJob(
                language: language, runner: .process(executable: "", arguments: []), input: "", directory: params.single[":dir"],
                block: location, blockText: texts.joined(separator: "\n"), alwaysAsk: query, finish: finishBase(.generic), needs: [needed.need]
            )
            job.approved = texts
            return .success(job)
        } catch let error as Failure {
            return .failure(error)
        } catch {
            return .failure(.message("\(error)"))
        }
        if useCache, !inline, !needsFile, params.single[":cache"] == "yes" {
            do {
                let state = try cacheState(language: language, params: params, tables: tables, body: body, location: location, name: name,
                                           call: location != block.range, text: ns, options: options, model: model)
                if state.current { return .failure(.message(cachedMessage(state.value))) }
                // Appended or prepended results accumulate, so they carry no hash.
                if params.results.contains("replace") { hash = state.hash }
            } catch let error as Failure {
                return .failure(error)
            } catch {
                return .failure(.message("\(error)"))
            }
        }
        let blockText = ns.substring(with: NSRange(location))
        let dir = params.single[":dir"]
        let alwaysAsk = eval == "query"

        if shells.contains(language) {
            let valueIsExitStatus = params.results.contains("value")
            let executable = language == "shell" ? options.shell : language
            let lines = shellAssignments(vars, shell: executable, params: params)
            let cmdline = params.single[":cmdline"]
            let shebang = params.single[":shebang"].flatMap { $0.contains(where: { !$0.isWhitespace }) ? $0 : nil }
            if stdin != nil || cmdline != nil || (session == nil && shebang != nil) {
                // `org-babel-sh-evaluate`: an executable script, run by the shell with the
                // command line after it and `:stdin` as its input; the result is its standard
                // output, or its exit status for `:results value`. `:stdin` and `:cmdline`
                // run it even with a session, which the script doesn't use.
                var script = (shebang ?? "#!/usr/bin/env \(executable)") + "\n"
                if params.single[":padline"] != "no" { script += "\n" }
                script += (lines + [body]).joined(separator: "\n") + (valueIsExitStatus ? "\necho $?" : "")
                let command = Babel.scriptFileToken + (stdin != nil || cmdline != nil ? " " + (cmdline ?? "") : "")
                var job = BabelJob(
                    language: language, runner: .process(executable: executable, arguments: ["-c", command]),
                    input: stdin.map { shellString($0) } ?? "", directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk,
                    finish: finishBase(.shell(valueIsExitStatus: valueIsExitStatus))
                )
                job.script = script
                return .success(job)
            }
            let full = (lines + [body]).joined(separator: "\n") + (valueIsExitStatus ? "\necho $?" : "")
            return .success(BabelJob(
                language: language, runner: session.map { .session(name: $0, executable: executable, python: false) } ?? .process(executable: executable, arguments: []),
                input: full.trimmingCharacters(in: .whitespacesAndNewlines) + "\n", directory: dir,
                block: location, blockText: blockText, alwaysAsk: alwaysAsk,
                finish: finishBase(.shell(valueIsExitStatus: valueIsExitStatus))
            ))
        }
        if language == "python", let session {
            // `org-babel-python--eval-ast`: the body at top level in the session, the value its
            // last expression's.
            let lines = vars.map { "\($0.0)=\(pythonLiteral($0.1))" }
            let source = (lines + [body]).joined(separator: "\n")
            let literal = String(data: try! JSONSerialization.data(withJSONObject: [source]), encoding: .utf8)!.dropFirst().dropLast()
            let program: String
            if output {
                program = "exec(compile(\(literal), '<org-babel>', 'exec'), globals())\n"
            } else {
                program = pythonFormatter + """
                    import ast as __orgstar_ast
                    __orgstar_tree = __orgstar_ast.parse(\(literal))
                    __orgstar_last = None
                    if __orgstar_tree.body and isinstance(__orgstar_tree.body[-1], __orgstar_ast.Expr):
                        __orgstar_last = __orgstar_ast.Expression(__orgstar_tree.body.pop().value)
                    exec(compile(__orgstar_tree, '<org-babel>', 'exec'), globals())
                    __orgstar_format(eval(compile(__orgstar_last, '<org-babel>', 'eval'), globals()) if __orgstar_last else None, '\(resultFileToken)', [
                    """ + params.results.map { "\"\($0)\"" }.joined(separator: ", ") + "])\n"
            }
            return .success(BabelJob(
                language: language, runner: .session(name: session, executable: params.single[":python"] ?? options.python, python: true),
                input: program, directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk, finish: finishBase(.python)
            ))
        }
        if language == "python" {
            let lines = vars.map { "\($0.0)=\(pythonLiteral($0.1))" }
            var full = (lines + [body]).joined(separator: "\n")
            if let returnValue = params.single[":return"], !output { full += "\nreturn \(returnValue)" }
            let input: String
            if output {
                input = full + "\n"
            } else {
                input = pythonFormatter + "def main():\n" + shiftRight(full) + "\n\n__orgstar_format(main(), '\(resultFileToken)', ["
                    + params.results.map { "\"\($0)\"" }.joined(separator: ", ") + "])\n"
            }
            return .success(BabelJob(
                language: language, runner: .process(executable: params.single[":python"] ?? options.python, arguments: []),
                input: input, directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk,
                finish: finishBase(.python)
            ))
        }
        if language == "emacs-lisp" || language == "elisp" {
            let bindings = vars.map { "(\($0.0) '\(lispLiteral($0.1)))" }
            let expanded = bindings.isEmpty ? body + "\n" : "(let (\(bindings.joined(separator: "\n      ")))\n\(body)\n)"
            let form = output ? "(with-output-to-string \(expanded))" : "(progn \(expanded)\n)"
            var job = BabelJob(
                language: language, runner: .emacs, input: emacsScript(form: form, params: params.results),
                directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk, finish: finishBase(.emacsLisp)
            )
            job.lispForm = form
            return .success(job)
        }
        if ["dot", "plantuml", "mermaid"].contains(language) {
            // ob-dot, ob-plantuml and ob-mermaid: the program draws into `:file`.
            guard let file else { return .failure(.message("\(language) code blocks need a :file header argument")) }
            let quoted = "'" + file.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            let ext = (file as NSString).pathExtension.isEmpty ? "png" : (file as NSString).pathExtension
            let cmdline = params.single[":cmdline"].map { " " + $0 } ?? ""
            var input = body + "\n"
            let command: String
            switch language {
            case "dot":
                command = "dot\(cmdline) -T\(ext) -o \(quoted)"
            case "plantuml":
                if body.range(of: "^[ \\t]*@start", options: .regularExpression) == nil { input = "@startuml\n" + body + "\n@enduml\n" }
                command = "plantuml\(cmdline) -p -t\(ext) > \(quoted)"
            default:
                command = "f=$(mktemp).mmd; cat > \"$f\"; mmdc\(cmdline) -i \"$f\" -o \(quoted); s=$?; rm -f \"$f\"; exit $s"
            }
            var finish = finishBase(.generic)
            finish.file = file
            finish.writesFile = true
            finish.params = params.results.filter { !["table", "scalar", "verbatim", "list", "vector"].contains($0) } + (params.results.contains("file") ? [] : ["file"])
            return .success(BabelJob(
                language: language, runner: .process(executable: "/bin/sh", arguments: ["-c", command]),
                input: input, directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk, finish: finish
            ))
        }
        if compiled {
            do {
                let heading = model.headings.lastIndex { $0.headingRange.lowerBound <= location.lowerBound }
                let run = try compiledRun(language: language, body: body, tables: tables, params: params,
                                          properties: { inheritedProperty($0, heading: heading, model: model) })
                var finish = finishBase(.compiled)
                // ob-clojure doesn't reassemble tables.
                if language == "clojure" { (finish.colnames, finish.rownames) = (nil, nil) }
                var job = BabelJob(language: language, runner: .process(executable: "/bin/sh", arguments: [scriptFileToken]), input: run.source,
                                   directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk, finish: finish)
                job.script = run.script
                job.programs = run.programs
                return .success(job)
            } catch let error as Failure {
                return .failure(error)
            } catch {
                return .failure(.message("\(error)"))
            }
        }
        if let (executable, arguments) = generic[language] {
            guard vars.isEmpty else { return .failure(.message(":var isn't supported for \(language) yet.")) }
            return .success(BabelJob(
                language: language, runner: .process(executable: params.single[":cmd"] ?? executable, arguments: arguments),
                input: body + "\n", directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk,
                finish: BabelJob.Finish(kind: .generic, language: language, params: params.results + (output ? [] : ["output"]), output: true, wrap: params.wrap, name: name, inline: inline, hash: hash)
            ))
        }
        return .failure(.message("No way to run \(language) blocks yet."))
    }

    public enum Failure: Error, Equatable {
        case message(String)
    }

    // MARK: - Noweb

    /// `org-babel-noweb-p` in the `:eval` context.
    static func nowebEvaluates(_ value: String?) -> Bool {
        (value ?? "").split(whereSeparator: \.isWhitespace).contains { ["yes", "no-export", "strip-export", "eval", "strip-tangle"].contains(String($0)) }
    }

    /// `org-babel-noweb-p` for `:tangle`.
    static func nowebTangles(_ value: String?) -> Bool {
        (value ?? "").split(whereSeparator: \.isWhitespace).contains { ["yes", "tangle", "no-export", "strip-export", "strip-tangle"].contains(String($0)) }
    }

    /// `org-babel-expand-noweb-references` for evaluation: each `<<name>>` becomes the body of
    /// the block named so, or of every block with that `:noweb-ref`, joined by `:noweb-sep`, or
    /// the contents of the heading with that ID; the text before it on its line goes before
    /// each line it brings.
    /// `tangling` expands the blocks it brings in as tangling would (`:noweb tangle`), not as
    /// evaluation does.
    /// `links` gives a block's begin and end comments, for `:comments noweb` when tangling.
    static func expandNoweb(_ block: SrcBlockInfo, params: Params, model: DocumentModel, text: NSString, tangling: Bool = false, depth: Int = 0,
                            links: ((SrcBlockInfo, Params) throws -> (begin: String, end: String))? = nil) throws -> String {
        guard depth < 32 else { throw Failure.message("Noweb references nest too deeply") }
        let body = normalizedBody(block)
        let prefixing = params.single[":noweb-prefix"].map { $0 != "no" && $0 != "nil" } ?? true
        let commenting = tangling && links != nil && params.single[":comments"] == "noweb"
        func expand(_ other: SrcBlockInfo) throws -> String {
            let otherParams = try Params(block: other, model: model, text: text)
            let expands = tangling ? nowebTangles(otherParams.single[":noweb"]) : nowebEvaluates(otherParams.single[":noweb"])
            let b = expands
                ? try expandNoweb(other, params: otherParams, model: model, text: text, tangling: tangling, depth: depth + 1, links: links)
                : normalizedBody(other)
            guard commenting, let links else { return b }
            // `c-wrap`: commented in this block's language, trimmed.
            func wrap(_ s: String) throws -> String {
                try Tangle.commentRegion(s, language: block.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var (begin, end) = try links(other.name == nil ? block : other, other.name == nil ? params : otherParams)
            // A `:noweb-ref` block without a name: the link is the including block's, the name empty.
            if other.name == nil {
                if let split = begin.range(of: "][") { begin = begin[..<split.lowerBound] + "][]]" }
                end = " ends here"
            }
            return try wrap(begin) + "\n" + b + "\n" + (try wrap(end)) + "\n"
        }
        func inCommentedHeading(_ b: SrcBlockInfo) -> Bool {
            guard let h = b.heading else { return false }
            return ([h] + model.ancestors(of: h)).contains { model.headings[$0].title == "COMMENT" || model.headings[$0].title.hasPrefix("COMMENT ") }
        }
        let regex = try! NSRegularExpression(pattern: "(.*?)(<<([^ \\t\\n](?:.*?[^ \\t\\n])?)>>)")
        let ns = body as NSString
        var out = ""
        var at = 0
        for m in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let prefix = ns.substring(with: m.range(at: 1))
            let id = ns.substring(with: m.range(at: 3))
            out += ns.substring(with: NSRange(location: at, length: m.range(at: 2).location - at))
            at = NSMaxRange(m.range)
            var expansion = ""
            if id.range(of: "\\(.*\\)", options: .regularExpression) != nil {
                throw Failure.message("Noweb references that run a block (\(id)) aren't supported yet; nothing was run.")
            } else if let heading = model.headings.firstIndex(where: { h in
                h.properties.contains { ($0.key.uppercased() == "ID" && $0.value == id) || ($0.key.uppercased() == "CUSTOM_ID" && "#" + $0.value == id) }
            }) {
                expansion = headlineBody(heading, model: model, text: text)
            } else if let named = model.srcBlocks.first(where: { $0.name == id }), !inCommentedHeading(named) {
                expansion = try expand(named)
            } else {
                var parts: [String] = []
                var separators: [String] = []
                for other in model.srcBlocks where !inCommentedHeading(other) {
                    let p = try Params(block: other, model: model, text: text)
                    guard p.single[":noweb-ref"] == id else { continue }
                    parts.append(try expand(other))
                    separators.append(p.single[":noweb-sep"] ?? "\n")
                }
                for (i, part) in parts.enumerated() {
                    if i > 0 { expansion += separators[i - 1] }
                    expansion += part
                }
            }
            out += prefixing ? expansion.components(separatedBy: CharacterSet(charactersIn: "\n\r")).joined(separator: "\n" + prefix) : expansion
        }
        return out + ns.substring(from: at)
    }

    /// `org-babel-ref-headline-body`: the entry after its planning and drawers.
    static func headlineBody(_ index: Int, model: DocumentModel, text: NSString) -> String {
        let heading = model.headings[index]
        let buffer = EmacsBuffer(text as String, point: heading.headingRange.lowerBound)
        buffer.endOfMetaData()
        let start = buffer.point
        let end = model.headings[(index + 1)...].first.map { $0.headingRange.lowerBound } ?? text.length
        return start < end ? text.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// `org-babel--normalize-body`: without the final newline, and without the indentation
    /// common to its lines unless `-i` keeps it.
    static func normalizedBody(_ block: SrcBlockInfo) -> String {
        var lines = block.body.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // Org escapes lines starting with `*` or `#+` inside blocks with a comma.
        lines = lines.map { $0.replacingOccurrences(of: "^([ \\t]*),([,*]|#\\+)", with: "$1$2", options: .regularExpression) }
        if !block.switches.contains("-i") {
            let indents = lines.filter { $0.contains(where: { !$0.isWhitespace }) }.map { $0.prefix { $0 == " " || $0 == "\t" }.count }
            let common = indents.min() ?? 0
            lines = lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tables in variables

    /// Variables after `org-babel-disassemble-tables`, with the names taken off their tables.
    struct Tables {
        var vars: [(String, VarValue)] = []
        var colnames: [(name: String, names: [Cell])] = []
        var rownames: [(name: String, names: [Cell])] = []

        /// `org-babel-pick-name`: a Lisp list given as the header argument, or the last
        /// variable's names, unless the header argument is absent, whose `nil` selects none.
        func picked(_ names: [(name: String, names: [Cell])], _ key: String, _ params: Params) -> [String]? {
            if let list = params.evaluated[key].flatMap(Babel.lispNames) { return list }
            guard params.single[key] != nil, let last = names.last else { return nil }
            return last.names.map(Babel.cellText)
        }
    }

    /// A Lisp list of strings and numbers, as names.
    static func lispNames(_ value: Sexp) -> [String]? {
        guard case .list(let items) = value else { return nil }
        return try? items.map { item in
            if let s = item.string { return s }
            let printed = Elisp.printed(item)
            guard number(printed) == printed else { throw Failure.message(printed) }
            return printed
        }
    }

    static func cellText(_ c: Cell) -> String {
        switch c {
        case .number(let n): n
        case .text(let s): s
        }
    }

    /// `org-babel-disassemble-tables`: a table's header row comes off when `:colnames` asks, or
    /// by default when only its second row is a rule; its first column with `:rownames`; its
    /// rules unless `:hlines yes`.
    static func disassemble(_ vars: [(String, VarValue)], params: Params) throws -> Tables {
        for key in [":colnames", ":rownames"] where params.lisp.contains(key) && params.evaluated[key].flatMap(lispNames) == nil {
            throw Failure.message("\(key) \(params.single[key] ?? "") is Lisp that only Emacs can evaluate; nothing was run.")
        }
        let colnames = params.single[":colnames"]
        let rownames = params.single[":rownames"]
        let hlines = params.single[":hlines"] ?? "no"
        var tables = Tables()
        for (name, value) in vars {
            guard case .table(var rows) = value else {
                tables.vars.append((name, value))
                continue
            }
            let auto = rows.count > 1 && rows[0] != nil && rows[1] == nil && !rows.dropFirst(2).contains(where: { $0 == nil })
            if colnames != "no", colnames != nil || auto {
                while let first = rows.first, first == nil { rows.removeFirst() }
                if let header = rows.first ?? nil {
                    rows.removeFirst(rows.count > 1 && rows[1] == nil ? 2 : 1)
                    tables.colnames.append((name, header))
                }
            }
            if let rownames, rownames != "no" {
                let kept = rows.compactMap { $0 }
                tables.rownames.append((name, kept.map { $0.first ?? .text("") }))
                rows = kept.map { Array($0.dropFirst()) }
            }
            if hlines != "yes" { rows = rows.filter { $0 != nil } }
            tables.vars.append((name, .table(rows)))
        }
        return tables
    }

    /// `org-babel-reassemble-table` on a result.
    static func reassemble(_ value: Value, _ finish: BabelJob.Finish) -> Value {
        guard case .table(var rows) = value else { return value }
        if let names = finish.rownames, names.count == rows.count {
            var next = names.makeIterator()
            rows = rows.map { row in row.map { [next.next() ?? ""] + $0 } }
        }
        if let names = finish.colnames, let first = rows.first ?? nil, first.count == names.count {
            rows = [names, nil] + rows
        }
        return .table(rows)
    }

    /// A `:var` value that is Lisp (`org-babel-read`): evaluated, as a number, string, list or
    /// table.
    static func lispValue(_ value: String) throws -> VarValue {
        let refusal = Failure.message(":var value \(value) is Lisp that only Emacs can evaluate.")
        guard let form = try? LispReader.readFirst(value).sexp, let result = try? Elisp().eval(form) else { throw refusal }
        func cell(_ v: Sexp) throws -> Cell {
            if let s = v.string { return .text(s) }
            if let n = number(Elisp.printed(v)), Elisp.printed(v) == n { return .number(n) }
            throw refusal
        }
        if let s = result.string { return .scalar(s) }
        if case .list(let items) = result, !items.isEmpty {
            if items.allSatisfy({ if case .list = $0 { return true }; return $0 == .symbol("hline") }) {
                return .table(try items.map { item in
                    if item == .symbol("hline") { return nil }
                    guard case .list(let cells) = item else { throw refusal }
                    return try cells.map(cell)
                })
            }
            return .list(try items.map(cell))
        }
        if case .number(let n) = try? cell(result) { return .number(n) }
        throw refusal
    }

    // MARK: - Cache

    /// `:cache yes` (`org-babel-execute-src-block`): the block's hash, and whether its results
    /// already carry it, with their value when it can be read.
    static func cacheState(language: String, params: Params, tables: Tables, body: String, location: Range<Int>, name: String?,
                           call: Bool, text: NSString, options: Options, model: DocumentModel) throws -> (hash: String, current: Bool, value: VarValue?) {
        let heading = model.headings.lastIndex { $0.headingRange.lowerBound <= location.lowerBound }
        // The hash is taken outside the shell's own binding of `shell-file-name`, so its
        // variables are written for the user's shell whatever the block's language.
        let expanded = try languageExpansion(body, language: language, tables: tables, params: params,
                                             properties: { inheritedProperty($0, heading: heading, model: model) })
            ?? expandedBody(language: language, vars: tables.vars, body: body, shell: options.shell, params: params)
        let input = try cacheInput(language: language, params: params, tables: tables, expanded: expanded, call: call)
        let hash = Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let line = existingResults(name: name, block: location, text: text), resultsHash(at: line, text: text) == hash else {
            return (hash, false, nil)
        }
        return (hash, true, readResult(after: line, text: text))
    }

    static func cachedMessage(_ value: VarValue?) -> String {
        value.map { "Cached: " + lispLiteral($0) } ?? "Cached; nothing was run."
    }

    /// The body with its variables, as the language's `org-babel-expand-body:` writes it.
    static func expandedBody(language: String, vars: [(String, VarValue)], body: String, shell: String, params: Params) -> String {
        if shells.contains(language) {
            return (shellAssignments(vars, shell: shell, params: params) + [body]).joined(separator: "\n")
        }
        if language == "python" {
            return (vars.map { "\($0.0)=\(pythonLiteral($0.1))" } + [body]).joined(separator: "\n")
        }
        if language == "emacs-lisp" || language == "elisp" {
            let bindings = vars.map { "(\($0.0) '\(lispLiteral($0.1)))" }
            return bindings.isEmpty ? body + "\n" : "(let (\(bindings.joined(separator: "\n      ")))\n\(body)\n)"
        }
        return body
    }

    /// What `org-babel-sha1-hash` hashes: the header arguments after `org-babel-process-params`,
    /// sorted by key and printed with `%S`, then the expanded body.
    static func cacheInput(language: String, params: Params, tables: Tables, expanded: String, call: Bool) throws -> String {
        if let key = params.lisp.first(where: { params.evaluated[$0] == nil }) {
            throw Failure.message(":cache with \(key) \(params.single[key] ?? "") needs Emacs to evaluate the Lisp; nothing was run.")
        }
        let ignored: Set<String> = ["replace", "silent", "none", "discard", "append", "prepend"]
        let drawsFile = language == "dot" || language == "plantuml"
        // `org-babel-default-header-args`, the language's and `org-babel-default-lob-header-args`.
        var defaults = [":session": "none", ":exports": call || drawsFile ? "results" : "code", ":cache": "no", ":noweb": "no", ":hlines": "no", ":tangle": "no"]
        if language == "emacs-lisp" || language == "elisp" { defaults[":lexical"] = "no" }
        var entries: [(key: String, printed: String)] = []
        for (key, value) in defaults.merging(params.single, uniquingKeysWith: { $1 }) {
            let printed: String
            if let evaluated = params.evaluated[key] {
                printed = Elisp.printed(evaluated, escape: true)
            } else if value.isEmpty {
                continue
            } else if key == ":exports" {
                printed = lispString(value.split(whereSeparator: \.isWhitespace).map(String.init).filter { !ignored.contains($0) }.sorted().joined(separator: " "))
            } else if params.single[key] != nil, !params.quoted.contains(key), let n = number(value) {
                printed = n
            } else {
                printed = lispString(value)
            }
            entries.append((key, printed))
        }
        var words = params.results
        if drawsFile, !words.contains(where: { Params.resultGroups[0].contains($0) }) { words.append("file") }
        let kept = words.filter { !ignored.contains($0) }.sorted()
        if !kept.isEmpty { entries.append((":result-params", "(" + kept.map { lispString($0) }.joined(separator: " ") + ")")) }
        entries.append((":result-type", words.contains("output") ? "output" : "value"))
        entries.append((":results", lispString(kept.joined(separator: " "))))
        if let wrap = params.wrap, !wrap.isEmpty { entries.append((":wrap", lispString(wrap))) }
        for (key, names) in [(":colname-names", tables.colnames), (":rowname-names", tables.rownames)] where !names.isEmpty {
            entries.append((key, "(" + names.map { "(\($0.name) " + lispLiteral(.list($0.names)).dropFirst() }.joined(separator: " ") + ")"))
        }
        for (name, value) in tables.vars {
            switch value {
            case .scalar, .number: entries.append((":var", "(\(name) . \(lispLiteral(value)))"))
            case .list, .table: entries.append((":var", "(\(name) " + lispLiteral(value).dropFirst()))
            }
        }
        let sorted = entries.enumerated().sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }.map(\.element.printed)
        return sorted.joined(separator: ":") + "-" + expanded
    }

    /// `org-babel-read-result` for fixed-width lines, a table or a plain list after the
    /// `#+RESULTS` line at `line`; nil for anything else.
    static func readResult(after line: Int, text ns: NSString) -> VarValue? {
        var location = NSMaxRange(ns.lineRange(for: NSRange(location: line, length: 0)))
        var lines: [String] = []
        while location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: range).trimmingCharacters(in: .newlines)
            if content.trimmingCharacters(in: .whitespaces).isEmpty { break }
            lines.append(content.trimmingCharacters(in: .whitespaces))
            location = NSMaxRange(range)
        }
        guard let first = lines.first else { return nil }
        if first == ":" || first.hasPrefix(": ") {
            var fixed: [String] = []
            for l in lines {
                guard l == ":" || l.hasPrefix(": ") else { break }
                fixed.append(String(l.dropFirst(2)))
            }
            let value = fixed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return number(value).map(VarValue.number) ?? .scalar(value)
        }
        if first.hasPrefix("|") {
            var rows: [[Cell]?] = []
            for l in lines {
                guard l.hasPrefix("|") else { break }
                if l.hasPrefix("|-") {
                    rows.append(nil)
                    continue
                }
                let cells = l.dropFirst().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                rows.append((l.hasSuffix("|") ? Array(cells.dropLast()) : cells).map(cell))
            }
            return .table(rows)
        }
        if first.firstMatch(of: #/^[-+*] /#) != nil {
            var items: [Cell] = []
            for l in lines {
                guard let m = l.firstMatch(of: /^[-+*] (.*)$/) else { return nil }
                items.append(cell(String(m.1)))
            }
            return .list(items)
        }
        return nil
    }

    // MARK: - Header arguments

    struct Params {
        var results: [String] = ["replace"]
        var single: [String: String] = [:]
        var vars: [(name: String, value: String)] = []
        var wrap: String?
        /// Keys whose value is Lisp to evaluate (`org-babel-read`): unquoted, starting with `(`, `'`, `` ` `` or `[`.
        var lisp: Set<String> = []
        /// Keys whose value was a quoted string, which `org-babel-read` doesn't take for a number.
        var quoted: Set<String> = []
        /// Lisp values evaluated to something other than a string or number, such as a list of
        /// column names.
        var evaluated: [String: Sexp] = [:]

        /// `org-babel-read` on the Lisp values the interpreter can evaluate: a string or number
        /// takes the form's place; other values are kept in `evaluated`.
        mutating func evaluateLisp(file: String?) {
            for key in lisp {
                guard let form = try? LispReader.readFirst(single[key] ?? "").sexp,
                      let value = try? (file.map { Tangle.fileLisp(path: $0) } ?? Elisp()).eval(form) else { continue }
                let printed = Elisp.printed(value)
                if let s = value.string {
                    single[key] = s
                    quoted.insert(key)
                    lisp.remove(key)
                } else if Babel.number(printed) == printed {
                    single[key] = printed
                    lisp.remove(key)
                } else {
                    evaluated[key] = value
                }
            }
        }

        static let resultGroups: [Set<String>] = [
            ["file", "list", "vector", "table", "scalar", "verbatim"],
            ["raw", "html", "latex", "org", "code", "pp", "drawer", "link", "graphics"],
            ["replace", "silent", "none", "discard", "append", "prepend"],
            ["output", "value"],
        ]

        /// `defaults` go under the properties, as `org-babel-default-inline-header-args` do.
        init(block: SrcBlockInfo, model: DocumentModel, text: NSString, defaults: [(String, String)] = [], extra: [[(String, String)]] = [],
             inline: Bool = false) throws {
            var layers: [[(String, String)]] = [defaults, Babel.languageDefaults[block.language ?? ""] ?? []]
            layers += Params.propertyLayers(language: block.language ?? "", heading: block.heading, model: model)
            let firstLine = inline ? "" : text.substring(with: text.lineRange(for: NSRange(location: block.range.lowerBound, length: 0)))
            if let r = firstLine.range(of: "(?i)#\\+begin_src[ \\t]+\\S+", options: .regularExpression) {
                var rest = String(firstLine[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                while let first = rest.split(separator: " ").first, first.hasPrefix("-") || first.hasPrefix("+") {
                    rest = String(rest.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
                }
                layers.append(Params.parse(rest))
            }
            // `#+HEADER:` lines above the block.
            var headers: [String] = []
            var location = block.range.lowerBound
            while !inline, location > 0 {
                let previous = text.lineRange(for: NSRange(location: location - 1, length: 0))
                let line = text.substring(with: previous).trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.range(of: "(?i)^#\\+(header|name|caption|attr_[a-z]+|results|plot|label):", options: .regularExpression) != nil else { break }
                if line.lowercased().hasPrefix("#+header:") { headers.insert(String(line.dropFirst("#+header:".count)), at: 0) }
                location = previous.location
            }
            for header in headers { layers.append(Params.parse(header)) }
            layers += extra

            for layer in layers {
                for (key, raw) in layer {
                    let quoted = key != ":var" && raw.count >= 2 && raw.hasPrefix("\"") && raw.hasSuffix("\"")
                    let value = quoted ? Params.unescape(String(raw.dropFirst().dropLast())) : raw
                    if key != ":var" {
                        if !quoted, let first = value.first, "('`[".contains(first) { lisp.insert(key) } else { lisp.remove(key) }
                        if quoted { self.quoted.insert(key) } else { self.quoted.remove(key) }
                    }
                    switch key {
                    case ":results":
                        for word in value.split(whereSeparator: \.isWhitespace).map(String.init) {
                            if let group = Params.resultGroups.first(where: { $0.contains(word) }) { results.removeAll { group.contains($0) } }
                            results.removeAll { $0 == word }
                            results.insert(word, at: 0)
                        }
                    case ":var":
                        for value in Params.splitVars(value) {
                            guard let eq = value.firstIndex(of: "=") else { throw Failure.message(":var \(value) needs a name and a value") }
                            let name = value[..<eq].trimmingCharacters(in: .whitespaces)
                            let assigned = value[value.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                            vars.removeAll { $0.name == name }
                            vars.append((name, assigned))
                        }
                    case ":wrap":
                        wrap = value
                    default:
                        single[key] = value
                    }
                }
            }
        }

        /// `org-babel-params-from-properties` under `heading`, or before any: the inherited
        /// `header-args`, then the inherited `header-args:LANG`, each the nearest value with `+`
        /// additions after it.
        static func propertyLayers(language: String, heading: Int?, model: DocumentModel) -> [[(String, String)]] {
            var levels = [model.fileProperties]
            if let heading {
                levels += (model.ancestors(of: heading) + [heading]).map { model.headings[$0].properties }
            }
            return ["header-args", "header-args:\(language)"].compactMap { key in
                var value: String?
                for entries in levels {
                    for entry in entries where entry.key.lowercased() == key {
                        value = entry.additive ? [value, entry.value].compactMap { $0 }.joined(separator: " ") : entry.value
                    }
                }
                return value.map(Params.parse)
            }
        }

        /// `org-babel-parse-header-arguments`: split before each `:key` outside quotes and
        /// parentheses.
        /// A Lisp string's contents as `read` gives them.
        static func unescape(_ s: String) -> String {
            var out = ""
            var escaped = false
            for c in s {
                if escaped {
                    switch c {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(c)
                    }
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else {
                    out.append(c)
                }
            }
            return out
        }

        /// `org-babel-parse-multiple-vars`: one `:var` value holding several assignments split
        /// on spaces outside quotes and brackets, pieces split beside `=` joined again.
        static func splitVars(_ value: String) -> [String] {
            var pieces: [String] = []
            var current = ""
            var depth = 0
            var quoted = false
            var previous: Character = " "
            for c in value {
                if c == "\"", previous != "\\" { quoted.toggle() }
                previous = c
                if !quoted, "([{".contains(c) { depth += 1 }
                if !quoted, ")]}".contains(c) { depth = max(0, depth - 1) }
                if c == " ", !quoted, depth == 0 {
                    if !current.isEmpty { pieces.append(current) }
                    current = ""
                } else {
                    current.append(c)
                }
            }
            if !current.isEmpty { pieces.append(current) }
            var joined: [String] = []
            for piece in pieces {
                if let last = joined.last, last.hasSuffix("=") || piece.hasPrefix("=") {
                    joined[joined.count - 1] = last + piece
                } else {
                    joined.append(piece)
                }
            }
            return joined.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        static func parse(_ text: String) -> [(String, String)] {
            var parts: [String] = []
            var current = ""
            var depth = 0
            var quoted = false
            var previous: Character = " "
            for c in text {
                if c == "\"", previous != "\\" { quoted.toggle() }
                if !quoted {
                    if c == "(" { depth += 1 }
                    if c == ")" { depth = max(0, depth - 1) }
                }
                if c == ":", !quoted, depth == 0, previous == " " || previous == "\t" {
                    parts.append(current)
                    current = ""
                }
                current.append(c)
                previous = c
            }
            parts.append(current)
            var pairs: [(String, String)] = []
            for part in parts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(":") else { continue }
                let key = String(trimmed.prefix { !$0.isWhitespace }).lowercased()
                // Quotes stay until the value is used, so a quoted string isn't taken for Lisp.
                pairs.append((key, trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)))
            }
            return pairs
        }
    }

    // MARK: - Variables

    /// A referenced block's result as a `:var` value.
    static func varValue(_ finish: BabelJob.Finish, _ output: BabelOutput) -> VarValue {
        switch value(finish, output) {
        case .none: return .scalar("")
        case .string(let s): return number(s).map(VarValue.number) ?? .scalar(s)
        case .table(let rows): return .table(rows.map { $0?.map(cell) })
        }
    }

    enum VarValue: Equatable, Sendable {
        case scalar(String)
        case number(String)
        /// Rows; nil is a rule (`hline`).
        case table([[Cell]?])
        case list([Cell])
    }

    enum Cell: Equatable, Sendable {
        case text(String)
        case number(String)
    }

    /// `org-babel--string-to-number`, keeping Emacs's printed form.
    static func number(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace), t.range(of: "^[0-9e.+ -]+$", options: .regularExpression) != nil else { return nil }
        if t.range(of: "^[-+]?[0-9]+\\.?$", options: .regularExpression) != nil {
            var digits = t.hasSuffix(".") ? String(t.dropLast()) : t
            let negative = digits.hasPrefix("-")
            if digits.hasPrefix("-") || digits.hasPrefix("+") { digits.removeFirst() }
            digits = String(digits.drop { $0 == "0" })
            if digits.isEmpty { return "0" }
            return (negative ? "-" : "") + digits
        }
        guard t.range(of: "^[-+]?([0-9]+\\.[0-9]+|[0-9]*\\.[0-9]+|[0-9]+(\\.[0-9]*)?e[-+]?[0-9]+|[0-9]*\\.[0-9]+e[-+]?[0-9]+)$", options: .regularExpression) != nil,
              let d = Double(t) else { return nil }
        return emacsFloat(d)
    }

    /// How Emacs prints a float.
    static func emacsFloat(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
        return "\(d)"
    }

    static func cell(_ s: String) -> Cell {
        var t = s
        if let m = s.firstMatch(of: /^\s*"(.+)"\s*$/) { t = String(m.1) }
        return number(t).map(Cell.number) ?? .text(t)
    }

    /// `name` or `name(args)` naming a src block in the file: the block and its call arguments.
    static func referencedBlock(_ value: String, model: DocumentModel) -> (block: SrcBlockInfo, arguments: String?)? {
        guard let m = value.firstMatch(of: /^([^\s()\[\]"]+)(?:\((.*)\))?$/),
              let block = model.srcBlocks.first(where: { $0.name == String(m.1) }) else { return nil }
        return (block, m.2.map(String.init))
    }

    /// The blocks `params`' references run, directly or through theirs.
    static func referencedBlocks(_ params: Params, model: DocumentModel, text: NSString, seen: Set<String>) -> [SrcBlockInfo] {
        var found: [SrcBlockInfo] = []
        var seen = seen
        for value in params.vars.map(\.value) + [params.single[":stdin"]].compactMap({ $0 }) {
            guard let (block, arguments) = referencedBlock(value, model: model), let name = block.name, seen.insert(name).inserted else { continue }
            found.append(block)
            let extra = arguments.map { [splitArguments($0).map { (":var", $0) }] } ?? []
            if let inner = try? Params(block: block, model: model, text: text, extra: extra) {
                found += referencedBlocks(inner, model: model, text: text, seen: seen)
            }
        }
        return found
    }

    /// `org-babel-ref-resolve` for literals, named tables and lists in the file, and named src
    /// blocks, which run first (`Needed`) and give their result.
    static func resolve(_ value: String, model: DocumentModel, text: NSString, refs: References) throws -> VarValue {
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { return .scalar(Params.unescape(String(value.dropFirst().dropLast()))) }
        if let n = number(value) { return .number(n) }
        if let first = value.first, "('`[".contains(first) { return try lispValue(value) }
        if let known = refs.resolved[value] { return known }
        if let (block, arguments) = referencedBlock(value, model: model), let name = block.name {
            guard !refs.visiting.contains(name) else { throw Failure.message("\(name) refers to itself through :var") }
            let extra = arguments.map { [splitArguments($0).map { (":var", $0) }] } ?? []
            var inner = refs
            inner.visiting.insert(name)
            var params = try Params(block: block, model: model, text: text, extra: extra)
            params.evaluateLisp(file: refs.options.file)
            // A cached block gives its result without running, as `org-babel-execute-src-block` does.
            var useCache = true
            if params.single[":cache"] == "yes", let language = block.language {
                let tables = try disassemble(params.vars.map { ($0.name, try resolve($0.value, model: model, text: text, refs: inner)) }, params: params)
                let body = nowebEvaluates(params.single[":noweb"]) ? try expandNoweb(block, params: params, model: model, text: text) : normalizedBody(block)
                let state = try cacheState(language: language, params: params, tables: tables, body: body, location: block.range, name: name, call: false, text: text, options: refs.options, model: model)
                if state.current {
                    if let value = state.value { return value }
                    useCache = false
                }
            }
            switch plan(block, params: params, model: model, text: text,
                        options: refs.options, location: block.range, name: name, refs: inner, useCache: useCache) {
            case .failure(let failure): throw failure
            case .success(let job):
                throw Needed(need: job.needs.first ?? BabelJob.Need(reference: value, job: job))
            }
        }
        if value.contains("(") || value.contains("[") { throw Failure.message("References like \(value) aren't supported yet.") }
        // A named element: `#+NAME: value` above a table or list.
        let pattern = "(?im)^[ \\t]*#\\+name:[ \\t]*" + NSRegularExpression.escapedPattern(for: value) + "[ \\t]*$"
        guard let r = (text as String).range(of: pattern, options: .regularExpression) else {
            throw Failure.message("Can't find \(value) for :var.")
        }
        let start = NSMaxRange(text.lineRange(for: NSRange(r, in: text as String)))
        var location = start
        var rows: [[Cell]?] = []
        var items: [Cell] = []
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                if trimmed.hasPrefix("|-") {
                    rows.append(nil)
                    location = NSMaxRange(lineRange)
                    continue
                }
                let cells = trimmed.dropFirst().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                rows.append((trimmed.hasSuffix("|") ? Array(cells.dropLast()) : cells).map(cell))
            } else if let m = trimmed.firstMatch(of: /^[-+*] (.*)$/), rows.isEmpty {
                items.append(cell(String(m.1)))
            } else if trimmed.hasPrefix("#+") || (!rows.isEmpty || !items.isEmpty) {
                if rows.isEmpty, items.isEmpty, trimmed.lowercased().hasPrefix("#+begin_src") {
                    throw Failure.message("Using a src block's result in :var isn't supported yet.")
                }
                break
            } else {
                break
            }
            location = NSMaxRange(lineRange)
        }
        if !rows.isEmpty { return .table(rows) }
        if !items.isEmpty { return .list(items) }
        throw Failure.message("\(value) isn't a table or list.")
    }

    /// `org-babel-sh-var-to-string`: a table's rows as tab-separated lines, a list's items as
    /// lines.
    static func shellString(_ value: VarValue, separator: String? = nil, hline: String? = nil) -> String {
        switch value {
        case .scalar(let s), .number(let s): return s
        case .list(let items): return items.map(cellText).joined(separator: "\n")
        case .table(let rows): return rows.compactMap { $0?.map(cellText).joined(separator: separator ?? "\t") ?? hline }.joined(separator: "\n")
        }
    }

    /// `org-babel-variable-assignments:shell`, by the shell's name: for bash, an array for a
    /// list and an associative array for a table of two or more columns; `set` for fish; a
    /// quoted string otherwise.
    static func shellAssignments(_ vars: [(String, VarValue)], shell: String, params: Params) -> [String] {
        let separator = params.single[":separator"]
        let hline = params.single[":hlines"] == "yes" ? params.single[":hline-string"] ?? "hline" : nil
        func quoted(_ value: VarValue) -> String {
            "'" + shellString(value, separator: separator, hline: hline).replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        return vars.map { name, value in
            if shell.hasSuffix("bash") {
                switch value {
                case .table(let rows) where (rows.first ?? nil).map({ $0.count >= 2 }) ?? false:
                    let entries = rows.compactMap { $0 }.map { row in
                        "\(name)[\(quoted(.scalar(cellText(row[0]))))]=\(quoted(.list(Array(row.dropFirst()))))"
                    }
                    return (["unset \(name)", "declare -A \(name)"] + entries).joined(separator: "\n")
                case .table(let rows):
                    let items = rows.map { $0.map { quoted(.list($0)) } ?? quoted(.scalar("hline")) }
                    return "unset \(name)\ndeclare -a \(name)=( \(items.joined(separator: " ")) )"
                case .list(let items):
                    return "unset \(name)\ndeclare -a \(name)=( \(items.map { quoted(.scalar(cellText($0))) }.joined(separator: " ")) )"
                case .scalar, .number:
                    break
                }
            }
            return (shell.hasSuffix("fish") ? "set \(name) " : "\(name)=") + quoted(value)
        }
    }

    /// `org-babel-python-var-to-python`.
    static func pythonLiteral(_ value: VarValue) -> String {
        func cell(_ c: Cell) -> String {
            switch c {
            case .number(let n): return n
            case .text(let s): return lispString(s, triple: s.contains("\n") || s.contains("\r"))
            }
        }
        switch value {
        case .scalar(let s): return lispString(s, triple: s.contains("\n") || s.contains("\r"))
        case .number(let n): return n
        case .list(let items): return "[" + items.map(cell).joined(separator: ", ") + "]"
        case .table(let rows): return "[" + rows.map { $0.map { "[" + $0.map(cell).joined(separator: ", ") + "]" } ?? "None" }.joined(separator: ", ") + "]"
        }
    }

    /// `prin1` of a string.
    static func lispString(_ s: String, triple: Bool = false) -> String {
        let quoted = "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return triple ? "\"\"" + quoted + "\"\"" : quoted
    }

    static func lispLiteral(_ value: VarValue) -> String {
        func cell(_ c: Cell) -> String {
            switch c {
            case .number(let n): return n
            case .text(let s): return lispString(s)
            }
        }
        switch value {
        case .scalar(let s): return lispString(s)
        case .number(let n): return n
        case .list(let items): return "(" + items.map(cell).joined(separator: " ") + ")"
        case .table(let rows): return "(" + rows.map { $0.map { "(" + $0.map(cell).joined(separator: " ") + ")" } ?? "hline" }.joined(separator: " ") + ")"
        }
    }

    // MARK: - Python

    /// Writes the value of `main()` to the result file as org's Python wrapper does: `pprint`
    /// for `pp`, `key :: value` items for a dict as a list, dicts as rows for tables,
    /// otherwise `str`.
    static let pythonFormatter = """
    def __orgstar_format(value, path, params):
        def rows(v):
            if isinstance(v, dict):
                return [(k, rows(x)) for k, x in v.items()]
            if isinstance(v, (list, tuple)):
                return [rows(x) for x in v]
            return v
        with open(path, 'w') as out:
            if 'pp' in params:
                import pprint
                out.write(pprint.pformat(value))
            elif 'list' in params and isinstance(value, dict):
                out.write(str(['{} :: {}'.format(k, v) for k, v in value.items()]))
            else:
                if not set(params) & {'scalar', 'verbatim', 'raw'} and 'table' in params:
                    value = rows(value)
                out.write(str(value))

    """

    /// `org-babel-python--shift-right`: four spaces more on every line outside strings.
    static func shiftRight(_ body: String) -> String {
        var inString: String?
        var lines: [String] = []
        for line in body.components(separatedBy: "\n") {
            lines.append(inString == nil ? "    " + line : line)
            var i = line.startIndex
            while i < line.endIndex {
                if let delimiter = inString {
                    if line[i...].hasPrefix(delimiter) {
                        inString = nil
                        i = line.index(i, offsetBy: 3)
                        continue
                    }
                } else if line[i] == "#" {
                    break
                } else if line[i...].hasPrefix("\"\"\"") || line[i...].hasPrefix("'''") {
                    inString = String(line[i...].prefix(3))
                    i = line.index(i, offsetBy: 3)
                    continue
                } else if line[i] == "\"" || line[i] == "'" {
                    let quote = line[i]
                    i = line.index(after: i)
                    while i < line.endIndex, line[i] != quote {
                        if line[i] == "\\" { i = line.index(after: i) }
                        if i < line.endIndex { i = line.index(after: i) }
                    }
                }
                if i < line.endIndex { i = line.index(after: i) }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Emacs Lisp

    /// Evaluates `form` and prints the result as JSON: its `%s` and `%S` forms, and its rows
    /// when it is a table.
    static func emacsScript(form: String, params: [String]) -> String {
        """
        ;;; -*- lexical-binding: t -*-
        (require 'cl-lib)
        (require 'json)
        (let* ((result \(form))
               (print-level nil)
               (print-length nil)
               (cell (lambda (c) (if (stringp c) c (format "%s" c))))
               (tabulable (and (proper-list-p result)
                               (cl-every (lambda (e) (or (atom e) (proper-list-p e))) result)))
               (rows (and tabulable result
                          (if (cl-every (lambda (e) (or (eq e 'hline) (listp e))) result)
                              (mapcar (lambda (r) (if (eq r 'hline) "hline" (vconcat (mapcar cell r)))) result)
                            (list (vconcat (mapcar cell result)))))))
          (princ (json-encode `((s . ,(format "%s" result))
                                (S . ,(format "%S" result))
                                (string . ,(if (stringp result) t :json-false))
                                (rows . ,(if rows (vconcat rows) :json-null))))))
        """
    }

    /// An Emacs Lisp job run by `Elisp` instead of Emacs: the output `emacsScript` would print.
    /// A Lisp error fails the run, as it does in Emacs; nil when the block uses what `Elisp`
    /// doesn't have.
    public static func evaluateNatively(_ job: BabelJob) throws(Failure) -> BabelOutput? {
        guard let form = job.lispForm, let sexp = try? LispReader.readFirst(form).sexp else { return nil }
        let lisp = Elisp()
        let result: Sexp
        do {
            result = try lisp.eval(sexp)
        } catch is Elisp.Unsupported {
            return nil
        } catch {
            throw .message("\(error)")
        }
        func cell(_ c: Sexp) -> String { Elisp.printed(c) }
        func isProper(_ v: Sexp) -> Bool {
            if case .list = v { return true }
            return Elisp.isNil(v)
        }
        func isAtom(_ v: Sexp) -> Bool {
            switch v {
            case .list(let items): items.isEmpty
            case .dotted: false
            default: true
            }
        }
        var rows: [Any] = []
        if case .list(let items) = result, items.allSatisfy({ isAtom($0) || isProper($0) }) {
            if items.allSatisfy({ $0 == .symbol("hline") || isProper($0) }) {
                rows = items.map { $0 == .symbol("hline") ? "hline" as Any : ((try? Elisp.elements($0)) ?? []).map(cell) as Any }
            } else {
                rows = [items.map(cell)]
            }
        }
        var object: [String: Any] = ["s": Elisp.printed(result), "S": Elisp.printed(result, escape: true), "string": result.string != nil]
        object["rows"] = rows.isEmpty ? NSNull() : rows
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return nil }
        return BabelOutput(stdout: lisp.standardOutput + json, stderr: lisp.messages)
    }

    // MARK: - Finishing

    /// What the run produced, as Babel holds it before inserting.
    enum Value: Equatable {
        case none
        case string(String)
        /// Rows of cells; nil rows are rules.
        case table([[String]?])
    }

    /// The edit that writes the run's result under the block, or why it can't.
    public static func finish(_ job: BabelJob, output: BabelOutput, text: String, settings: OrgSettings = .default) -> Result<[TextEdit], Failure> {
        let ns = text as NSString
        var blockRange = job.block
        if blockRange.upperBound > ns.length || ns.substring(with: NSRange(blockRange)) != job.blockText {
            let found = ns.range(of: job.blockText)
            guard found.location != NSNotFound,
                  ns.range(of: job.blockText, range: NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))).location == NSNotFound else {
                return .failure(.message("The block changed while it ran; the result wasn't written."))
            }
            blockRange = found.location..<NSMaxRange(found)
        }
        let value = Self.value(job.finish, output)
        if job.finish.params.contains("silent") || job.finish.params.contains("none") || job.finish.params.contains("discard") { return .success([]) }
        let buffer = EmacsBuffer(text, point: 0, settings: settings)
        if job.finish.inline {
            do {
                try insertInlineResult(value, job.finish, at: blockRange, buffer: buffer)
            } catch let error as Failure {
                return .failure(error)
            } catch {
                return .failure(.message("\(error)"))
            }
            return .success(TextEdit.between(text, buffer.text as String))
        }
        insertResult(value, job.finish, block: blockRange, buffer: buffer)
        return .success(TextEdit.between(text, buffer.text as String))
    }

    /// The language's result handling: `org-babel-result-cond` and the table import.
    static func value(_ finish: BabelJob.Finish, _ output: BabelOutput) -> Value {
        reassemble(rawValue(finish, output), finish)
    }

    static func rawValue(_ finish: BabelJob.Finish, _ output: BabelOutput) -> Value {
        let params = finish.params
        if params.contains("file") {
            // `org-babel-result-to-file`: a link to `:file`, or to the result as a path.
            let path = finish.file ?? rawResult(finish, output)
            var link = "[[file:" + path + "]"
            if let description = finish.fileDescription { link += "[" + (description.isEmpty ? path : description) + "]" }
            return .string(link + "]")
        }
        let scalar = params.contains("scalar") || params.contains("verbatim") || params.contains("html") || params.contains("code")
            || params.contains("pp") || params.contains("file")
            || ((params.contains("output") || params.contains("raw") || params.contains("org")) && !params.contains("table"))
        switch finish.kind {
        case .shell(let valueIsExitStatus):
            var results = output.stdout
            if valueIsExitStatus {
                results = results.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            }
            if scalar { return .string(results) }
            return importTable(results)
        case .generic:
            return .string(output.stdout)
        case .python:
            let raw = finish.output ? output.stdout : (output.resultFile ?? "")
            if scalar { return .string(raw) }
            return pythonValue(raw)
        case .emacsLisp:
            guard let data = output.stdout.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .string(output.stdout) }
            if scalar {
                return .string((params.contains("scalar") || params.contains("verbatim") ? object["S"] : object["s"]) as? String ?? "")
            }
            if object["string"] as? Bool == true { return .string(object["s"] as? String ?? "") }
            if let rows = object["rows"] as? [Any] {
                return .table(rows.map { $0 as? String == "hline" ? nil : ($0 as? [String] ?? []) })
            }
            let printed = object["S"] as? String ?? ""
            return printed == "nil" ? .none : .string(printed)
        case .compiled:
            return compiledValue(finish, output, scalar: scalar)
        }
    }

    /// The result as the program left it, before tables are read.
    static func rawResult(_ finish: BabelJob.Finish, _ output: BabelOutput) -> String {
        switch finish.kind {
        case .python: return finish.output ? output.stdout : (output.resultFile ?? "")
        case .emacsLisp:
            guard let data = output.stdout.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return output.stdout }
            return object["s"] as? String ?? ""
        case .shell(let valueIsExitStatus):
            return valueIsExitStatus ? output.stdout.split(separator: "\n").last.map(String.init) ?? "" : output.stdout
        case .generic: return output.stdout
        case .compiled: return compiledResult(finish, output)
        }
    }

    /// With `:results file` and `:file`, what to write there, relative to the run's folder;
    /// nil when there's nothing to write or the program wrote it.
    public static func fileResult(_ job: BabelJob, output: BabelOutput) -> (path: String, contents: String)? {
        guard job.finish.params.contains("file"), let file = job.finish.file, !job.finish.writesFile else { return nil }
        return (file, rawResult(job.finish, output))
    }

    /// `org-babel-import-elisp-from-file`.
    static func importTable(_ results: String) -> Value {
        guard !results.isEmpty else { return .none }
        var lines = results.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let nonEmpty = lines.filter { !$0.isEmpty }
        let rows: [[String]]
        if !nonEmpty.isEmpty, nonEmpty.allSatisfy({ $0.contains("\t") }) {
            rows = lines.map { $0.components(separatedBy: "\t") }
        } else if !nonEmpty.isEmpty, nonEmpty.allSatisfy({ $0.contains(",") }) {
            rows = lines.map(csvFields)
        } else if lines.count == 1 {
            rows = [[lines[0]]]
        } else {
            rows = lines.map { line in
                let trimmed = line.drop { $0 == " " }
                return trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init).isEmpty
                    ? [""] : trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            }
        }
        let cells = rows.map { row in row.map { field -> String in
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            switch cell(trimmed) {
            case .number(let n): return n
            case .text(let t): return t
            }
        } }
        if cells.count == 1, cells[0].count == 1 { return .string(cells[0][0]) }
        return .table(cells)
    }

    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        for c in line {
            if c == "\"" {
                quoted.toggle()
            } else if c == ",", !quoted {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    /// `org-babel-python-table-or-string`; with `none` "null" and `braces`,
    /// `org-babel-java-table-or-string`, which reads `{…}` as a list too.
    static func pythonValue(_ raw: String, none: String = "None", braces: Bool = false) -> Value {
        guard let first = raw.first, let last = raw.last, raw.count >= 2,
              (first == "[" && last == "]") || (first == "(" && last == ")") || (braces && first == "{" && last == "}") else {
            if raw.isEmpty { return .string("") }
            if raw.count > 2, (raw.hasPrefix("'") && raw.hasSuffix("'")) || (raw.hasPrefix("\"") && raw.hasSuffix("\"")) {
                return .string(String(raw.dropFirst().dropLast()))
            }
            if let n = number(raw) { return .string(n) }
            return .string(raw)
        }
        var parser = PythonLiteral(Array(raw))
        parser.braces = braces
        guard let parsed = parser.parse(), parser.atEnd, case .list(let items) = parsed else { return .string(raw) }
        func text(_ v: PythonLiteral.Node) -> String {
            switch v {
            case .atom(let s): return s
            case .string(let s): return s
            case .list(let xs): return "(" + xs.map(text).joined(separator: " ") + ")"
            }
        }
        if items.allSatisfy({ if case .list = $0 { return true }; if case .atom(none) = $0 { return true }; return false }) {
            return .table(items.map { item -> [String]? in
                if case .list(let cells) = item { return cells.map(text) }
                return nil
            })
        }
        return .table([items.map { if case .atom(none) = $0 { return "hline" }; return text($0) }])
    }

    struct PythonLiteral {
        indirect enum Node: Equatable {
            case atom(String)
            case string(String)
            case list([Node])
        }

        let chars: [Character]
        var i = 0
        /// `{…}` is a list, as `org-babel-script-escape` reads it.
        var braces = false
        init(_ chars: [Character]) { self.chars = chars }
        var atEnd: Bool { mutating get { skip(); return i == chars.count } }

        mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "\n" { i += 1 } }

        mutating func parse() -> Node? {
            skip()
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == "[" || c == "(" || (braces && c == "{") {
                let close: Character = c == "[" ? "]" : c == "{" ? "}" : ")"
                i += 1
                var items: [Node] = []
                skip()
                if i < chars.count, chars[i] == close {
                    i += 1
                    return .list(items)
                }
                while true {
                    guard let item = parse() else { return nil }
                    items.append(item)
                    skip()
                    guard i < chars.count else { return nil }
                    if chars[i] == "," {
                        i += 1
                        skip()
                        if i < chars.count, chars[i] == close {
                            i += 1
                            return .list(items)
                        }
                        continue
                    }
                    if chars[i] == close {
                        i += 1
                        return .list(items)
                    }
                    return nil
                }
            }
            if c == "'" || c == "\"" {
                i += 1
                var s = ""
                while i < chars.count, chars[i] != c {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        default: s.append(chars[i])
                        }
                    } else {
                        s.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
                return .string(s)
            }
            var s = ""
            while i < chars.count, !",)] \n".contains(chars[i]), !(braces && chars[i] == "}") {
                s.append(chars[i])
                i += 1
            }
            guard !s.isEmpty else { return nil }
            return .atom(number(s) ?? s)
        }
    }

    // MARK: - Inserting

    static let resultKeyword = "(?i)^[ \\t]*#\\+results(\\[[^\\]]*\\])?:"

    /// `org-babel-where-is-src-block-result` with `insert`: the line of the block's results
    /// keyword, added when there is none.
    /// The `#+RESULTS` line of a block's results (`org-babel-where-is-src-block-result`):
    /// the one naming `name`, or for an unnamed block an empty one right after it.
    static func existingResults(name: String?, block: Range<Int>, text ns: NSString) -> Int? {
        if let name {
            let pattern = "(?im)^[ \\t]*#\\+results(\\[[^\\]]*\\])?:[ \\t]*" + NSRegularExpression.escapedPattern(for: name) + "[ \\t]*$"
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length))?.range.location
        }
        // The element after the block, past blank lines.
        var location = block.upperBound
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line)
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                location = NSMaxRange(line)
                continue
            }
            if content.range(of: "(?i)^[ \\t]*#\\+results(\\[[^\\]]*\\])?:[ \\t]*\\n?$", options: .regularExpression) != nil {
                return line.location
            }
            break
        }
        return nil
    }

    /// The hash in the `#+RESULTS[…]:` line at `line` (`org-babel-result-regexp`).
    static func resultsHash(at line: Int, text ns: NSString) -> String? {
        let content = ns.substring(with: ns.lineRange(for: NSRange(location: line, length: 0)))
        return content.firstMatch(of: #/(?i)^[ \t]*#\+results\[(?:\(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\) )?([0-9a-f]+)\]:/#).map { String($0.1) }
    }

    static func resultsLine(_ finish: BabelJob.Finish, block: Range<Int>, buffer: EmacsBuffer) -> Int {
        if let line = existingResults(name: finish.name, block: block, text: buffer.text) {
            // `org-babel--clear-results-maybe`: a different hash clears the results and
            // rewrites the keyword.
            if let hash = finish.hash, resultsHash(at: line, text: buffer.text) != hash {
                buffer.point = line
                let indent = String(buffer.substring(line, buffer.lineEnd(line)).prefix { $0 == " " || $0 == "\t" })
                buffer.forwardLine(1)
                let contents = buffer.point
                buffer.deleteRegion(contents, max(contents, resultEnd(buffer)))
                buffer.deleteRegion(line, contents)
                buffer.point = line
                buffer.insert(indent + "#+RESULTS[\(hash)]:" + (finish.name.map { " " + $0 } ?? "") + "\n")
                if buffer.looking("^[ \\t]*$", caseInsensitive: false, setsMatch: false) == nil {
                    buffer.saveExcursion { buffer.insert("\n") }
                }
            }
            return line
        }
        // A new keyword after the block.
        buffer.point = min(block.upperBound, buffer.length)
        buffer.skipBackward([32, 9, 10, 13])
        buffer.forwardLine(1)
        if !buffer.bolp { buffer.insert("\n") }
        let indent = buffer.saveExcursion { () -> String in
            buffer.point = block.lowerBound
            let line = buffer.substring(buffer.lineStart(buffer.point), buffer.lineEnd(buffer.point))
            return String(line.prefix { $0 == " " || $0 == "\t" })
        }
        buffer.insert("\n")
        let keywordLine = buffer.point
        buffer.insert(indent + "#+RESULTS" + (finish.hash.map { "[\($0)]" } ?? "") + ":" + (finish.name.map { " " + $0 } ?? "") + "\n")
        if buffer.looking("^[ \\t]*$", caseInsensitive: false, setsMatch: false) == nil {
            buffer.saveExcursion { buffer.insert("\n") }
        }
        return keywordLine
    }

    /// `org-babel-result-end` with point at the start of the result.
    static func resultEnd(_ buffer: EmacsBuffer) -> Int {
        let start = buffer.point
        let line = buffer.substring(buffer.lineStart(start), buffer.lineEnd(start))
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return start }
        if line.range(of: "^[ \\t]*\\[\\[[^\\]]+\\](\\[[^\\]]*\\])?\\][ \\t]*$", options: .regularExpression) != nil {
            return min(buffer.length, buffer.lineEnd(start) + 1)
        }
        let tree = OrgParser.parse(buffer.text as String)
        var node = tree.root
        var found: SyntaxNode?
        while let child = node.child(containing: start) {
            if child.range.lowerBound == start || (buffer.lineStart(child.range.lowerBound) == start) {
                if [.fixedWidth, .table, .plainList, .drawer, .block, .dynamicBlock, .latexFragment].contains(child.kind) {
                    found = child
                    break
                }
            }
            node = child
        }
        guard let element = found else { return start }
        var end = element.range.upperBound
        while end > start, let c = buffer.character(at: end - 1), c == 32 || c == 9 || c == 10 || c == 13 { end -= 1 }
        return min(buffer.length, buffer.lineEnd(end) + 1)
    }

    /// `org-babel-insert-result` for a src block.
    /// An inline block's result, after it: ` {{{results(=value=)}}}`, replacing one already
    /// there; raw results go in as they are.
    static func insertInlineResult(_ value: Value, _ finish: BabelJob.Finish, at object: Range<Int>, buffer: EmacsBuffer) throws {
        var string: String
        switch value {
        case .none: string = ""
        case .string(let s): string = s
        case .table(let rows):
            let cells = rows.compactMap { $0 }
            guard cells.count == 1, cells[0].count == 1 else { throw Failure.message("Inline source block results can't be tables or lists") }
            string = cells[0][0]
        }
        buffer.point = object.upperBound
        if let existing = buffer.lookingAt("[ \\t]*\\{\\{\\{results\\(.*?\\)\\}\\}\\}") {
            buffer.deleteRegion(existing[0]!.lowerBound, existing[0]!.upperBound)
        }
        if finish.params.contains("raw") {
            buffer.insert(" " + string)
            return
        }
        if string.hasSuffix("\n") { string.removeLast() }
        guard !string.contains("\n") else { throw Failure.message("Inline source block results must be one line") }
        buffer.insert(" {{{results(=" + string + "=)}}}")
    }

    static func insertResult(_ value: Value, _ finish: BabelJob.Finish, block: Range<Int>, buffer: EmacsBuffer) {
        let params = finish.params
        let keyword = resultsLine(finish, block: block, buffer: buffer)
        buffer.point = keyword
        let indent = buffer.substring(buffer.lineStart(keyword), buffer.lineEnd(keyword)).prefix { $0 == " " || $0 == "\t" }.count
        buffer.forwardLine(1)
        if buffer.point == buffer.lineEnd(keyword) { buffer.insert("\n") }
        var beg = buffer.point
        if params.contains("replace") {
            buffer.deleteRegion(beg, resultEnd(buffer))
            buffer.point = beg
        } else if params.contains("append") {
            buffer.point = resultEnd(buffer)
            beg = buffer.point
        }
        var tabulated = false
        // A list made from a string is examplified, as a string result is.
        var listed = false
        switch value {
        case .none:
            break
        case .string(var s) where params.contains("list"):
            if s.last != "\n" { s += "\n" }
            let items = s.split(separator: "\n", omittingEmptySubsequences: true)
            buffer.insert(items.map { "- " + $0 }.joined(separator: "\n") + "\n")
        case .table(let rows) where params.contains("list"):
            listed = true
            let items = rows.count == 1 ? (rows[0] ?? []) : rows.compactMap { $0?.joined(separator: " ") }
            buffer.insert(items.map { "- " + $0 }.joined(separator: "\n") + "\n")
        case .table(let rows):
            tabulated = true
            let lines = rows.map { row in row.map { "| " + $0.map { " " + $0 + " " }.joined(separator: "|").dropFirst() + " |" } ?? "|-" }
            let start = buffer.point
            buffer.insert(lines.joined(separator: "\n") + "\n")
            buffer.point = start
            buffer.tableAlign()
            buffer.point = buffer.tableEnd()
        case .string(var s):
            if !s.isEmpty, s.last != "\n" { s += "\n" }
            buffer.insert(s)
        }
        let end = buffer.marker(buffer.point, advances: true)
        defer { buffer.release(end) }
        func wrap(_ open: String, _ close: String, escape: Bool) {
            buffer.point = end.position
            buffer.insert(close + "\n")
            buffer.point = beg
            buffer.insert(open + "\n")
            if escape { escapeCode(buffer, from: buffer.point, to: end.position - close.utf16.count - 1) }
        }
        if let wrapValue = finish.wrap {
            let full = wrapValue.isEmpty ? "results" : wrapValue
            let type = String(full.split(separator: " ").first ?? "results")
            if type.lowercased() != "nil", type.lowercased() != "no" {
                wrap("#+begin_" + full, "#+end_" + type, escape: !["example", "src", "export"].contains(type.lowercased()) ? false : true)
            }
        } else if params.contains("html") {
            wrap("#+begin_export html", "#+end_export", escape: true)
        } else if params.contains("latex") {
            wrap("#+begin_export latex", "#+end_export", escape: true)
        } else if params.contains("org") {
            wrap("#+begin_src org", "#+end_src", escape: true)
        } else if params.contains("code") {
            wrap("#+begin_src \(finish.language.isEmpty ? "none" : finish.language)", "#+end_src", escape: true)
        } else if params.contains("raw") || params.contains("file") {
            // As inserted.
        } else if params.contains("drawer") {
            wrap(":results:", ":end:", escape: false)
        } else if !tabulated, !(params.contains("list") && listed) {
            examplify(buffer, beg, end.position)
        }
        if indent > 0, !(tabulated && params.contains("append")) {
            buffer.point = beg
            while buffer.point < end.position {
                if !buffer.eolp { buffer.insert(String(repeating: " ", count: indent)) }
                if buffer.forwardLine(1) != 0 { break }
            }
        }
    }

    /// `org-escape-code-in-region`.
    static func escapeCode(_ buffer: EmacsBuffer, from start: Int, to end: Int) {
        buffer.point = start
        let stop = buffer.marker(end)
        defer { buffer.release(stop) }
        while buffer.point < stop.position {
            let line = buffer.substring(buffer.point, buffer.lineEnd(buffer.point))
            if let m = line.firstMatch(of: /^[ \t]*(,*(\*|#\+))/) {
                buffer.point += line[..<m.1.startIndex].utf16.count
                buffer.insert(",")
            }
            if buffer.forwardLine(1) != 0 { break }
        }
    }

    /// `org-babel-examplify-region`: fewer than ten lines get `: `, more an example block.
    static func examplify(_ buffer: EmacsBuffer, _ beg: Int, _ end: Int) {
        let text = buffer.substring(beg, end)
        var size = text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 1 : 0)
        if text.isEmpty { size = 0 }
        guard size > 0 else { return }
        if size < 10 {
            buffer.point = beg
            for _ in 0..<size {
                buffer.point = buffer.lineStart(buffer.point)
                buffer.insert(": ")
                buffer.forwardLine(1)
            }
            return
        }
        let endMarker = buffer.marker(end)
        defer { buffer.release(endMarker) }
        buffer.point = beg
        buffer.insert("#+begin_example\n")
        escapeCode(buffer, from: buffer.point, to: endMarker.position)
        buffer.point = endMarker.position
        if !buffer.bolp { buffer.insert("\n") }
        buffer.insert("#+end_example")
        if !buffer.eolp { buffer.insert("\n") }
    }
}

/// C-c C-c in a src block: `org-babel-execute-src-block`.
public struct ExecuteSrcBlock: OrgCommand {
    public init() {}
    public var id: String { "org.babel.execute" }
    public var title: String { "Run Source Block" }
    public func applies(in context: EditContext) -> Bool { KeyContext.holds("src", in: context) || Self.atCallOrInline(context) }

    /// On a `#+CALL:` line, an inline `call_` or an inline `src_` block.
    static func atCallOrInline(_ context: EditContext) -> Bool {
        let ns = context.text as NSString
        let line = ns.substring(with: ns.lineRange(for: NSRange(location: min(context.caret, ns.length), length: 0)))
        if line.range(of: "(?i)^[ \\t]*#\\+CALL:", options: .regularExpression) != nil { return true }
        var node = context.tree.root
        while let child = node.child(containing: context.caret) {
            if child.kind == .inlineSourceBlock || child.kind == .inlineBabelCall { return true }
            node = child
        }
        return false
    }

    public func run(in context: EditContext) -> CommandStep {
        switch Babel.plan(context) {
        case .success(let job): return .external(.babel(job))
        case .failure(.message(let message)): return .failed(message)
        }
    }
}
