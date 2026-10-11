import Foundation

extension Babel {
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
        case .script(let js, _):
            let raw = rawResult(finish, output)
            if scalar { return .string(raw) }
            // `org-babel-ruby-table-or-string`, its nils rules.
            return js ? jsValue(raw) : pythonValue(raw, none: "nil", braces: true)
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
        case .script(let js, let session): return finish.output || (js && !session) ? output.stdout : (output.resultFile ?? "")
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
