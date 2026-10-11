import CryptoKit
import Foundation

extension Babel {
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
}
