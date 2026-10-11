import Foundation

extension Babel {
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
}
