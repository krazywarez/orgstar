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
        /// `script`: ruby and js, whose value comes back as their `inspect` prints it, from
        /// the result file for ruby and the output for js.
        enum Kind: Sendable, Equatable { case shell(valueIsExitStatus: Bool), python, generic, emacsLisp, compiled, script(js: Bool) }
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
        let wraps = compiled || shells.contains(language) || ["python", "emacs-lisp", "elisp"].contains(language) || generic[language] != nil
        for key in [":prologue", ":epilogue", ":post", ":stdin", ":shebang"] where params.single[key] != nil
            && !(shells.contains(language) && [":stdin", ":shebang"].contains(key)) && !(wraps && [":prologue", ":epilogue"].contains(key)) {
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
                script += expandGeneric(body, lines, params) + (valueIsExitStatus ? "\necho $?" : "")
                let command = Babel.scriptFileToken + (stdin != nil || cmdline != nil ? " " + (cmdline ?? "") : "")
                var job = BabelJob(
                    language: language, runner: .process(executable: executable, arguments: ["-c", command]),
                    input: stdin.map { shellString($0) } ?? "", directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk,
                    finish: finishBase(.shell(valueIsExitStatus: valueIsExitStatus))
                )
                job.script = script
                return .success(job)
            }
            let full = expandGeneric(body, lines, params) + (valueIsExitStatus ? "\necho $?" : "")
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
            let source = expandGeneric(body, lines, params)
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
            var full = expandGeneric(body, lines, params)
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
            // `org-babel-expand-body:emacs-lisp` adds the prologue and epilogue only with variables.
            let prologue = params.single[":prologue"].map { $0 + "\n      " } ?? ""
            let epilogue = params.single[":epilogue"].map { "\n      " + $0 + "\n" } ?? ""
            let expanded = bindings.isEmpty ? body + "\n" : "(let (\(bindings.joined(separator: "\n      ")))\n\(prologue)\(body)\(epilogue)\n)"
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
            switch language {
            case "ruby":
                let full = expandGeneric(body, vars.map { "\($0.0)=\(rubyLiteral($0.1))" }, params)
                return .success(BabelJob(
                    language: language, runner: .process(executable: params.single[":ruby"] ?? executable, arguments: arguments),
                    input: output ? full : rubyWrapper(full, pp: params.results.contains("pp")), directory: dir, block: location, blockText: blockText,
                    alwaysAsk: alwaysAsk, finish: finishBase(.script(js: false))
                ))
            case "js", "javascript":
                let full = expandGeneric(body, vars.map { "var \($0.0)=\(jsLiteral($0.1));" }, params)
                return .success(BabelJob(
                    language: language, runner: .process(executable: params.single[":cmd"] ?? executable, arguments: arguments),
                    input: output ? full : jsWrapper(full), directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk,
                    finish: finishBase(.script(js: true))
                ))
            case "awk":
                // `org-babel-expand-body:awk`; the variables go on the command line.
                let full = (params.single[":prologue"].map { $0 + "\n" } ?? "") + body + (params.single[":epilogue"].map { "\n" + $0 + "\n" } ?? "")
                return .success(BabelJob(
                    language: language, runner: .process(executable: "/bin/sh", arguments: ["-c", awkCommand(vars, params: params)]),
                    input: full, directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk,
                    finish: finishBase(.shell(valueIsExitStatus: false))
                ))
            default:
                let lines = language == "R" ? vars.map { name, value in
                    rAssignment(name, value, colnames: tables.colnames.first { $0.0 == name }?.1, colnamesYes: params.single[":colnames"] == "yes",
                                rownamesYes: params.single[":rownames"] == "yes")
                } : []
                return .success(BabelJob(
                    language: language, runner: .process(executable: params.single[":cmd"] ?? executable, arguments: arguments),
                    input: expandGeneric(body, lines, params) + "\n", directory: dir, block: location, blockText: blockText, alwaysAsk: alwaysAsk,
                    finish: BabelJob.Finish(kind: .generic, language: language, params: params.results + (output ? [] : ["output"]), output: true, wrap: params.wrap, name: name, inline: inline, hash: hash)
                ))
            }
        }
        return .failure(.message("No way to run \(language) blocks yet."))
    }

    public enum Failure: Error, Equatable {
        case message(String)
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
