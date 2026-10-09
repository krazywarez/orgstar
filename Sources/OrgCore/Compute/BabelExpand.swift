import Foundation

// `org-babel-expand-body:LANG` of ob-C (C, C++, cpp, D), ob-java, ob-fortran and ob-clojure
// (Org 9.8.7), which tangling, the `:cache` hash and runs use, and their `org-babel-execute:LANG`:
// a script that writes the expansion to a file, compiles it and runs it.

extension Babel {
    static let expandedLanguages: Set<String> = ["C", "C++", "cpp", "D", "java", "fortran", "clojure"]

    /// The body as the language's `org-babel-expand-body:` writes it, or nil for other languages.
    /// `properties` gives inherited properties where the block is, which D's and Fortran's
    /// expansions read; tangling reads them outside the Org buffer, so never.
    static func languageExpansion(_ body: String, language: String, tables: Tables, params: Params,
                                  properties: (String) -> String? = { _ in nil }) throws -> String? {
        switch language {
        case "C", "C++", "cpp": return try expandC(body, d: false, tables: tables, params: params)
        case "D": return try expandC(body, d: true, tables: tables, params: params, properties: properties)
        case "java": return try expandJava(body, vars: tables.vars, params: params)
        case "fortran": return try expandFortran(body, vars: tables.vars, params: params, properties: properties)
        case "clojure": return expandClojure(body, vars: tables.vars, params: params)
        default: return nil
        }
    }

    enum HeaderValue {
        case string(String)
        case items([String])

        /// `split-string` of a string, or the items.
        var words: [String] {
            switch self {
            case .string(let s): s.split(whereSeparator: \.isWhitespace).map(String.init)
            case .items(let items): items
            }
        }
    }

    /// A header value as `org-babel-read` gives it: a string, or the items of a Lisp list;
    /// nil when absent.
    static func headerValue(_ key: String, _ params: Params) throws -> HeaderValue? {
        guard let raw = params.single[key] else { return nil }
        var value = params.evaluated[key]
        if value == nil, params.lisp.contains(key) {
            guard let form = try? LispReader.readFirst(raw).sexp, let result = try? Elisp().eval(form) else {
                throw Failure.message("\(key) \(raw) is Lisp that only Emacs can evaluate.")
            }
            value = result
        }
        guard let value else { return .string(raw) }
        if let s = value.string { return .string(s) }
        if Elisp.isNil(value) { return .items([]) }
        guard case .list(let items) = value else { throw Failure.message("\(key) \(raw) isn't a list of names.") }
        return .items(items.map { $0.string ?? Elisp.printed($0) })
    }

    /// `org-babel-read` of a property value: Lisp evaluated, a quoted string read, else the
    /// string.
    static func propertyValue(_ value: String?) throws -> HeaderValue? {
        guard let value else { return nil }
        guard let first = value.first, "('`[".contains(first) else {
            guard case .string(let s) = read(value) else { return .string(value) }
            return .string(s)
        }
        guard let form = try? LispReader.readFirst(value).sexp, let result = try? Elisp().eval(form) else {
            throw Failure.message("The property value \(value) is Lisp that only Emacs can evaluate.")
        }
        if let s = result.string { return .string(s) }
        if Elisp.isNil(result) { return .items([]) }
        guard case .list(let items) = result else { throw Failure.message("The property value \(value) isn't a list of names.") }
        return .items(items.map { $0.string ?? Elisp.printed($0) })
    }

    /// `(org-entry-get nil KEY t)` under `heading`, or before any: the nearest value from
    /// `#+PROPERTY` down the outline, with `KEY+` additions.
    static func inheritedProperty(_ key: String, heading: Int?, model: DocumentModel) -> String? {
        var levels = [model.fileProperties]
        if let heading { levels += (model.ancestors(of: heading) + [heading]).map { model.headings[$0].properties } }
        var value: String?
        for entries in levels {
            for entry in entries where entry.key.uppercased() == key.uppercased() {
                value = entry.additive ? [value, entry.value].compactMap { $0 }.joined(separator: " ") : entry.value
            }
        }
        return value
    }

    enum BaseType { case integer, float, string }

    /// `org-babel-C-val-to-base-type` and `org-babel-java-val-to-base-type`.
    static func baseType(_ cells: [Cell]) -> BaseType? {
        var type: BaseType?
        for cell in cells {
            switch cell {
            case .text: type = .string
            case .number(let n) where n.contains(".") || n.contains("e") || n.contains("N"):
                if type != .string { type = .float }
            case .number:
                if type == nil { type = .integer }
            }
        }
        return type
    }

    static func cells(_ value: VarValue) throws -> [Cell] {
        switch value {
        case .scalar(let s): return [.text(s)]
        case .number(let n): return [.number(n)]
        case .list(let items): return items
        case .table(let rows):
            guard !rows.contains(where: { $0 == nil }) else { throw Failure.message("Tables with rules in :var aren't supported for this language yet.") }
            return rows.flatMap { $0! }
        }
    }

    // MARK: - C, C++ and D

    static let cColumnUtility = """

        #ifndef _STRING_H
        #include <string.h>
        #endif
        int get_column_num (int nbcols, const char** header, const char* column)
        {
          int c;
          for (c=0; c<nbcols; c++)
            if (strcmp(header[c],column)==0)
              return c;
          return -1;
        }

        """
    static let dColumnUtility = """
        int get_column_num (string[] header, string column)
        {
          foreach (c, h; header)
            if (h==column)
              return to!int(c);
          return -1;
        }

        """

    /// `org-babel-C-expand-C` and `org-babel-C-expand-D`.
    static func expandC(_ body: String, d: Bool, tables: Tables, params: Params, properties: (String) -> String? = { _ in nil }) throws -> String {
        let vars = tables.vars
        func typeName(_ type: BaseType?) throws -> String {
            switch type {
            case .integer: return "int"
            case .float: return "double"
            case .string: return d ? "string" : "const char*"
            case nil: throw Failure.message("A :var value has no type C can take.")
            }
        }
        func literal(_ cell: Cell, _ type: BaseType) -> String {
            type == .string ? "\"" + cellText(cell) + "\"" : cellText(cell)
        }
        // `org-babel-C-var-to-C`.
        let declarations = try vars.map { name, value -> String in
            let type = try baseType(cells(value))
            let typeName = try typeName(type)
            var suffix = ""
            let data: String
            switch value {
            case .scalar, .number:
                data = literal(try cells(value)[0], type!)
            case .list(let items):
                suffix = "[\(items.count)]"
                data = (d ? "[" : "{") + items.map { literal($0, type!) }.joined(separator: ",") + (d ? "]" : "}")
            case .table(let rows):
                let rows = rows.map { $0! }
                suffix = d ? "[\(rows.first?.count ?? 0)][\(rows.count)]" : "[\(rows.count)][\(rows.first?.count ?? 0)]"
                data = (d ? "[\n" : "{\n")
                    + rows.map { (d ? " [" : " {") + $0.map { literal($0, type!) }.joined(separator: ",") + (d ? "]" : "}") }.joined(separator: ",\n")
                    + (d ? "\n]" : "\n}")
            }
            return d ? "\(typeName)\(suffix) \(name) = \(data);" : "\(typeName) \(name)\(suffix) = \(data);"
        }
        // `org-babel-C-table-sizes-to-C`.
        let sizes = vars.map { name, value -> String in
            switch value {
            case .table(let rows): "const int \(name)_rows = \(rows.count);\nconst int \(name)_cols = \(rows.first??.count ?? 0);"
            case .list(let items): "const int \(name)_cols = \(items.count);"
            case .scalar, .number: ""
            }
        }
        // `org-babel-C-header-to-C`.
        let headers = try tables.colnames.map { table, names -> String in
            let value = vars.first { $0.0 == table }?.1
            let typeName = try typeName(try value.map(cells).flatMap(baseType))
            let quoted = names.map { "\"" + cellText($0) + "\"" }.joined(separator: ",")
            return d
                ? "string[\(names.count)] \(table)_header = [\(quoted)];\n\(typeName) \(table)_h (size_t row, string col) { return \(table)[row][get_column_num(\(table)_header,col)]; }"
                : "const char* \(table)_header[\(names.count)] = {\(quoted)};\n\(typeName) \(table)_h (int row, const char* col) { return \(table)[row][get_column_num(\(names.count),\(table)_header,col)]; }"
        }
        var body = body
        var parts: [String] = []
        if d {
            // `:imports`, or the inherited IMPORTS property.
            parts.append("module mmm;")
            let imports = try headerValue(":imports", params) ?? propertyValue(properties("imports"))
            parts.append(((imports?.words ?? []) + ["std.stdio", "std.conv"]).map { "import \($0);" }.joined(separator: "\n"))
        } else {
            let includes = try headerValue(":includes", params)?.words ?? []
            parts.append(includes.map { $0.hasPrefix("<") ? "#include \($0)" : "#include \"\($0)\"" }.joined(separator: "\n"))
            var defines: [String] = []
            switch try headerValue(":defines", params) {
            case .string(let s):
                let words = HeaderValue.string(s).words
                defines = stride(from: 0, to: words.count - 1, by: 2).map { words[$0] + " " + words[$0 + 1] }
            case .items(let items): defines = items
            case nil: break
            }
            parts.append(defines.map { "#define \($0)" }.joined(separator: "\n"))
            parts.append((try headerValue(":namespaces", params)?.words ?? []).map { "using namespace \($0);" }.joined(separator: "\n"))
            body = (params.single[":prologue"].map { $0 + "\n" } ?? "") + body + (params.single[":epilogue"].map { "\n" + $0 + "\n" } ?? "")
        }
        parts.append(declarations.joined(separator: "\n"))
        parts.append(sizes.joined(separator: "\n"))
        parts.append(tables.colnames.isEmpty ? "" : d ? dColumnUtility : cColumnUtility)
        parts.append(headers.joined(separator: "\n"))
        // `org-babel-C-ensure-main-wrap`.
        let hasMain = body.range(of: "(?im)^[ \\t]*[intvod]+[ \\t\\n\\r]*main[ \\t]*\\(.*\\)", options: .regularExpression) != nil
        parts.append(params.single[":main"] == "no" || hasMain ? body : "int main() {\n\(body)\nreturn 0;\n}\n")
        parts.append("\n")
        return parts.joined(separator: "\n")
    }

    // MARK: - Java

    static let javaSpace = "[ \\t\\n\\r\\f]"
    static let javaPackage = try! NSRegularExpression(pattern: "(?im)^\(javaSpace)*package\(javaSpace)+([\\p{L}\\p{N}_.]+)\(javaSpace)*;$")
    static let javaImports = try! NSRegularExpression(pattern: "(?im)^\(javaSpace)*import(?:\(javaSpace)+static)?\(javaSpace)+([\\p{L}\\p{N}_.*]+)\(javaSpace)*;$")
    static let javaClass = try! NSRegularExpression(pattern: "(?im)^\(javaSpace)*(?:public\(javaSpace)+)?class\(javaSpace)+([\\p{L}\\p{N}_]+)\(javaSpace)*\\{")
    static let javaMain = try! NSRegularExpression(pattern: "(?im)^\(javaSpace)*public\(javaSpace)+static\(javaSpace)+void\(javaSpace)+main\(javaSpace)*\\(\(javaSpace)*String"
        + "[\\p{L}\\p{N}_\\[\\] \\t\\n\\r\\f]+\\)\(javaSpace)*(?:throws[\\p{L}\\p{N}_,. \\t\\n\\r\\f]+)?\\{")
    static let javaMethod = try! NSRegularExpression(pattern: "(?im)^\(javaSpace)*(?:[\\p{L}\\p{N}]+\(javaSpace)+)?(?:static\(javaSpace)+)?[\\p{L}\\p{N}_\\[\\]]+\(javaSpace)+[\\p{L}\\p{N}_]+"
        + "\(javaSpace)*\\([\\p{L}\\p{N}_\\[\\], \\t\\n\\r\\f]*\\)\(javaSpace)*(?:throws[\\p{L}\\p{N}_,. \\t\\n\\r\\f]+)?\\{")

    /// `org-babel-expand-body:java`: the body wrapped in a `main` method when it has no method,
    /// and in a class when it has none, with `:var` as static fields, `:imports` and the
    /// package of `:classname`.
    static func expandJava(_ body: String, vars: [(String, VarValue)], params: Params) throws -> String {
        let fullName = params.single[":classname"] ?? javaClassName(body)
        let className = fullName.components(separatedBy: ".").last!
        let packageName = fullName.contains(".") ? (fullName as NSString).deletingPathExtension : nil
        let varLines = try vars.map { name, value -> String in
            // A rule is `hline`, a string.
            let typed: [Cell]
            if case .table(let rows) = value, rows.contains(where: { $0 == nil }) {
                typed = rows.compactMap { $0 }.flatMap { $0 } + [.text("hline")]
            } else {
                typed = try cells(value)
            }
            guard let type = baseType(typed) else { throw Failure.message("A :var value has no type java can take.") }
            let base = type == .integer ? "Integer" : type == .float ? "Double" : "String"
            func literal(_ cell: Cell?) throws -> String {
                guard let cell else { return "null" }
                switch type {
                case .integer: return cellText(cell)
                case .float: return String(format: "%f", Double(cellText(cell)) ?? 0)
                case .string:
                    let s = cellText(cell)
                    if s.range(of: ".\\n+.", options: .regularExpression) != nil { throw Failure.message("Java does not support multiline string literals") }
                    return "\"" + s + "\""
                }
            }
            let declared: String
            let data: String
            switch value {
            case .scalar, .number:
                declared = base
                data = try literal(try cells(value)[0])
            case .list(let items):
                declared = "List<\(base)>"
                data = "Arrays.asList(" + (try items.map { try literal($0) }).joined(separator: ", ") + ")"
            case .table(let rows):
                declared = "List<List<\(base)>>"
                data = "Arrays.asList(" + (try rows.map { row in
                    try row.map { "Arrays.asList(" + (try $0.map { try literal($0) }).joined(separator: ", ") + ")" } ?? "null"
                }).joined(separator: ", ") + ")"
            }
            return "    static \(declared) \(name) = \(data);"
        }
        let imports = try headerValue(":imports", params).map { value -> [String] in
            guard case .string(let s) = value else { throw Failure.message(":imports for java takes a string.") }
            return s.components(separatedBy: " ")
        }

        let buffer = NSMutableString(string: (params.single[":prologue"].map { $0 + "\n" } ?? "") + body + (params.single[":epilogue"].map { "\n" + $0 } ?? ""))
        func search(_ regex: NSRegularExpression, from point: Int) -> NSTextCheckingResult? {
            regex.firstMatch(in: buffer as String, options: [.withTransparentBounds, .withoutAnchoringBounds],
                             range: NSRange(location: point, length: buffer.length - point))
        }
        // `org-babel-java--move-past`.
        func movePast(_ regex: NSRegularExpression, _ point: inout Int) {
            while let m = search(regex, from: point) { point = min(NSMaxRange(m.range) + 1, buffer.length) }
        }
        func wrap(_ opening: String) {
            var point = 0
            movePast(javaPackage, &point)
            movePast(javaImports, &point)
            buffer.insert(opening, at: point)
            indentRigidly(buffer, from: point + opening.utf16.count, by: 4)
            buffer.append("\n}")
        }
        if search(javaMain, from: 0) == nil, search(javaMethod, from: 0) == nil { wrap("public static void main(String[] args) {\n") }
        if search(javaClass, from: 0) == nil { wrap("\npublic class \(className) {\n") }
        if !varLines.isEmpty {
            var point = 0
            movePast(javaClass, &point)
            buffer.insert(varLines.joined(separator: "\n") + "\n", at: point)
        }
        if let imports {
            var point = 0
            movePast(javaPackage, &point)
            buffer.insert(imports.map { "import \($0);" }.joined(separator: "\n") + "\n", at: point)
        }
        if let packageName, search(javaPackage, from: 0) == nil { buffer.insert("package \(packageName);\n", at: 0) }
        return buffer as String
    }

    /// `org-babel-java-find-classname`.
    static func javaClassName(_ body: String) -> String {
        let ns = body as NSString
        func first(_ regex: NSRegularExpression) -> String? {
            regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        let package = first(javaPackage)
        let className = first(javaClass)
        if let package, let className { return package + "." + className }
        return className ?? package.map { $0 + ".Main" } ?? "Main"
    }

    /// `indent-code-rigidly` from `start`, at the beginning of a line, to the end: each line
    /// not starting inside a string moved right, blank lines emptied, with `indent-tabs-mode` nil.
    static func indentRigidly(_ buffer: NSMutableString, from start: Int, by columns: Int) {
        var location = start
        var inString = false
        while location < buffer.length {
            if !inString {
                var end = location
                var column = 0
                while end < buffer.length, let c = UnicodeScalar(buffer.character(at: end)), c == " " || c == "\t" {
                    column = c == "\t" ? (column / 8 + 1) * 8 : column + 1
                    end += 1
                }
                let atEnd = end >= buffer.length || buffer.character(at: end) == 10
                let indent = atEnd ? "" : String(repeating: " ", count: column + columns)
                buffer.replaceCharacters(in: NSRange(location: location, length: end - location), with: indent)
            }
            let line = buffer.lineRange(for: NSRange(location: location, length: 0))
            var escaped = false
            for i in line.location..<NSMaxRange(line) {
                let c = buffer.character(at: i)
                if escaped { escaped = false } else if c == 92 { escaped = true } else if c == 34 { inString.toggle() }
            }
            location = NSMaxRange(line)
        }
    }

    // MARK: - Fortran

    /// `org-babel-expand-body:fortran`.
    static func expandFortran(_ body: String, vars: [(String, VarValue)], params: Params, properties: (String) -> String? = { _ in nil }) throws -> String {
        let prologue = params.single[":prologue"]
        let epilogue = params.single[":epilogue"]
        // `%S`.
        func printed(_ cell: Cell) -> String {
            switch cell {
            case .number(let n): n
            case .text(let s): lispString(s)
            }
        }
        // `org-babel-fortran-var-to-fortran`.
        let declarations = try vars.map { name, value -> String in
            switch value {
            case .number(let n) where baseType([.number(n)]) == .integer: return "integer, parameter  ::  \(name) = \(n)\n"
            case .number(let n): return "real, parameter ::  \(name) = \(n)\n"
            case .scalar(let s): return "character(len=\(s.unicodeScalars.count)), parameter ::  \(name) = '\(s)'\n"
            case .table(let rows):
                guard !rows.contains(where: { $0 == nil }) else { throw Failure.message("Tables with rules in :var aren't supported for fortran yet.") }
                let rows = rows.map { $0! }
                let columns = rows.first?.count ?? 0
                let data = "(/" + rows.map { "(/" + $0.map(printed).joined(separator: ", ") + "/)" }.joined(separator: ", ") + "/)"
                return "real, parameter :: \(name)(\(rows.count),\(columns)) = transpose( reshape( \(data) , (/ \(columns), \(rows.count) /) ) )\n"
            case .list(let items):
                return "real, parameter :: \(name)(\(items.count)) = (/" + items.map(printed).joined(separator: ", ") + "/)\n"
            }
        }
        func items(_ value: HeaderValue?) -> [String] {
            switch value {
            case .string(let s): [s]
            case .items(let items): items
            case nil: []
            }
        }
        let includes = items(try headerValue(":includes", params) ?? propertyValue(properties("includes")))
        let defines = items(try headerValue(":defines", params) ?? propertyValue(properties("defines")))
        let main: String
        if params.single[":main"] == "no" {
            main = (prologue.map { $0 + "\n" } ?? "") + body + (epilogue.map { "\n" + $0 + "\n" } ?? "")
        } else {
            // Org writes the prologue again where the epilogue would go.
            let inner = declarations.joined(separator: "\n") + (prologue.map { $0 + "\n" } ?? "") + body + (prologue.map { $0 + "\n" } ?? "")
            if inner.range(of: "(?im)^[ \\t]*program\\b", options: .regularExpression) != nil {
                if !vars.isEmpty { throw Failure.message("Cannot use :vars if `program' statement is present") }
                main = inner
            } else {
                main = "program main\n\(inner)\nend program main\n"
            }
        }
        return [includes.map { "#include \($0)" }.joined(separator: "\n"), defines.map { "#define \($0)" }.joined(separator: "\n"), main, "\n"]
            .joined(separator: "\n")
    }

    // MARK: - Clojure

    /// `org-babel-expand-body:clojure`, for a backend other than CIDER's (whose namespace
    /// only matters with `:ns`, which is then used).
    static func expandClojure(_ body: String, vars: [(String, VarValue)], params: Params) -> String {
        var expanded = params.single[":ns"].map { "(ns \($0))\n" } ?? ""
        if vars.isEmpty {
            expanded += body.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let uncommented = body.replacingOccurrences(of: "(?m)^[ ]*;+.*$", with: "", options: .regularExpression)
            expanded += "(let [" + vars.map { "\($0.0) '\(lispLiteral($0.1))" }.joined(separator: "\n      ") + "]\n\(uncommented))"
        }
        expanded = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        if params.results.contains("output") { return expanded }
        let printer = params.results.contains("code") || params.results.contains("pp")
            ? "(require '[clojure.pprint :refer [pprint]]) (pprint "
            : "(prn "
        return printer + "(binding [*out* (java.io.StringWriter.)]" + expanded + "))"
    }

    // MARK: - Running

    /// A compiled language's run: `source` on the script's standard input, which the script
    /// writes to a file, compiles and runs with a newline as standard input, as
    /// `org-babel-eval` gives each command; the compiler's output is dropped.
    struct CompiledRun {
        let source: String
        let script: String
        let programs: [[String]]
    }

    /// `org-babel-C-execute`, `org-babel-execute:java`, `org-babel-execute:fortran` and
    /// `org-babel-execute:clojure` with the babashka or Clojure CLI backend, with Org's
    /// default compilers.
    static func compiledRun(language: String, body: String, tables: Tables, params: Params, properties: (String) -> String?) throws -> CompiledRun {
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        /// A string, or a Lisp list's items joined by spaces.
        func joined(_ value: HeaderValue?) -> String {
            switch value {
            case .string(let s): s
            case .items(let items): items.joined(separator: " ")
            case nil: ""
            }
        }
        func command(_ s: String) -> String { String(s.prefix { !$0.isWhitespace }) }
        let expanded = try languageExpansion(body, language: language, tables: tables, params: params, properties: properties)!
        let cmdline = params.single[":cmdline"].map { " " + $0 } ?? ""
        let flags = joined(try headerValue(":flags", params))
        let start = "d=$(mktemp -d) || exit 1\n"
        let end = "s=$?\nrm -rf \"$d\"\nexit $s\n"
        switch language {
        case "C", "C++", "cpp":
            let (compiler, ext) = language == "C" ? ("gcc", "c") : ("g++", "cpp")
            let libs = joined(try headerValue(":libs", params) ?? propertyValue(properties("libs")))
            let script = start + "cat > \"$d/C-src.\(ext)\"\necho | \(compiler) -o \"$d/C-bin\" \(flags) \"$d/C-src.\(ext)\" \(libs) > /dev/null\n"
                + "echo | \"$d/C-bin\"\(cmdline)\n" + end
            return CompiledRun(source: expanded, script: script, programs: [[compiler]])
        case "D":
            // rdmd compiles and runs.
            let script = start + "cat > \"$d/C-src.d\"\necho | rdmd \(flags) \"$d/C-src.d\"\(cmdline)\n" + end
            return CompiledRun(source: expanded, script: script, programs: [["rdmd"]])
        case "fortran":
            let script = start + "cat > \"$d/fortran-src.F90\"\necho | gfortran -o \"$d/fortran-bin\" \(flags) \"$d/fortran-src.F90\" > /dev/null\n"
                + "echo | \"$d/fortran-bin\"\(cmdline)\n" + end
            return CompiledRun(source: expanded, script: script, programs: [["gfortran"]])
        case "java":
            let javac = params.single[":javac"] ?? "javac"
            let java = params.single[":java"] ?? "java"
            let fullName = params.single[":classname"] ?? javaClassName(body)
            let className = fullName.components(separatedBy: ".").last!
            let packageName = fullName.contains(".") ? (fullName as NSString).deletingPathExtension : nil
            // Without `:dir` (Java's default is "."), in a temporary folder without the
            // package; else in the run's folder, under the package's folders.
            let fromTemp = params.single[":dir"] == nil
            let source = javaForEvaluation(expanded, suppressPackage: fromTemp, value: !params.results.contains("output"))
            let cmpflag = params.single[":cmpflag"] ?? ""
            let flags = params.single[":cmdline"] ?? ""
            let cmdargs = params.single[":cmdargs"] ?? ""
            let script: String
            if fromTemp {
                script = start + "cat > \"$d/\(className).java\"\n"
                    + "echo | { \(javac) \(cmpflag) \"$d/\(className).java\" && \(java) -cp \"$d/\" \(flags) \(className) \(cmdargs); }\n" + end
            } else {
                let folder = packageName.map { $0.replacingOccurrences(of: ".", with: "/") + "/" } ?? ""
                let file = quoted(folder + className + ".java")
                script = (folder.isEmpty ? "" : "mkdir -p \(quoted(folder))\n") + "cat > \(file)\n"
                    + "echo | { \(javac) \(cmpflag) \(file) && \(java) -cp \"$PWD/\" \(flags) \(fullName) \(cmdargs); }\n"
            }
            return CompiledRun(source: source, script: script, programs: [[command(javac)], [command(java)]])
        case "clojure":
            let file = "\"$d/clojure-cmd-script.clj\""
            let run: String
            let programs: [String]
            switch params.single[":backend"] {
            case nil:
                // `org-babel-clojure-backend`: babashka when installed, else the Clojure CLI.
                run = "if command -v bb > /dev/null 2>&1; then echo | bb \(file); else echo | clojure -M \(file); fi\n"
                programs = ["bb", "clojure"]
            case "babashka":
                run = "echo | bb \(file)\n"
                programs = ["bb"]
            case "clojure-cli":
                run = "echo | clojure -M \(file)\n"
                programs = ["clojure"]
            case let backend?:
                throw Failure.message("The \(backend) backend for clojure needs Emacs; Orgstar runs babashka or clojure-cli.")
            }
            return CompiledRun(source: expanded, script: start + "cat > \(file)\n" + run + end, programs: [programs])
        default:
            throw Failure.message("No way to run \(language) blocks yet.")
        }
    }

    /// `org-babel-java--result-wrapper`, writing to the result file.
    static let javaResultWrapper = """

            public static String __toString(Object val) {
                if (val instanceof String) {
                    return "\\"" + val + "\\"";
                } else if (val == null) {
                    return "null";
                } else if (val.getClass().isArray()) {
                    StringBuffer sb = new StringBuffer();
                    Object[] vals = (Object[])val;
                    sb.append("[");
                    for (int ii=0; ii<vals.length; ii++) {
                        sb.append(__toString(vals[ii]));
                        if (ii<vals.length-1)
                            sb.append(",");
                    }
                    sb.append("]");
                    return sb.toString();
                } else if (val instanceof List) {
                    StringBuffer sb = new StringBuffer();
                    List vals = (List)val;
                    sb.append("[");
                    for (int ii=0; ii<vals.size(); ii++) {
                        sb.append(__toString(vals.get(ii)));
                        if (ii<vals.size()-1)
                            sb.append(",");
                    }
                    sb.append("]");
                    return sb.toString();
                } else {
                    return String.valueOf(val);
                }
            }

            public static void main(String[] args) throws IOException {
                BufferedWriter output = new BufferedWriter(new FileWriter("\(resultFileToken)"));
                output.write(__toString(_main(args)));
                output.close();
            }
        """

    /// `org-babel-java--expand-for-evaluation`: without the package when run from a temporary
    /// folder, a `main` method when there is none, the value written to the result file, and
    /// the imports those need.
    static func javaForEvaluation(_ body: String, suppressPackage: Bool, value: Bool) -> String {
        let buffer = NSMutableString(string: body)
        func search(_ regex: NSRegularExpression, from point: Int) -> NSTextCheckingResult? {
            regex.firstMatch(in: buffer as String, options: [.withTransparentBounds, .withoutAnchoringBounds],
                             range: NSRange(location: point, length: buffer.length - point))
        }
        func movePast(_ regex: NSRegularExpression) -> Int {
            var point = 0
            while let m = search(regex, from: point) { point = min(NSMaxRange(m.range) + 1, buffer.length) }
            return point
        }
        if suppressPackage, let m = search(javaPackage, from: 0) { buffer.replaceCharacters(in: m.range, with: "") }
        if search(javaMain, from: 0) == nil {
            buffer.insert("\n    public static void main(String[] args) {\n        System.out.print(\"success\");\n    }\n\n", at: movePast(javaClass))
        }
        if value {
            let point = movePast(javaClass)
            buffer.insert(javaResultWrapper, at: point)
            let after = point + javaResultWrapper.utf16.count
            let main = buffer.range(of: "public static void main(", options: .caseInsensitive, range: NSRange(location: after, length: buffer.length - after))
            if main.location != NSNotFound { buffer.replaceCharacters(in: main, with: "public static Object _main(") }
        }
        // `org-babel-java--import-maybe`, with `case-fold-search`.
        for (package, name) in [("java.util", "List"), ("java.util", "Arrays"), ("java.io", "BufferedWriter"), ("java.io", "FileWriter"), ("java.io", "IOException")] {
            let used = buffer.range(of: name, options: .caseInsensitive).location != NSNotFound
            let imported = buffer.range(of: "(?im)^import .*\(package).*(?:\\*|\(name));", options: .regularExpression).location != NSNotFound
            if used, !imported { buffer.insert("import \(package).\(name);\n", at: movePast(javaPackage)) }
        }
        return buffer as String
    }

    /// A compiled language's result before it is read: standard output without its common
    /// indentation, trimmed for Fortran; Java's value from the result file; Clojure's as printed.
    static func compiledResult(_ finish: BabelJob.Finish, _ output: BabelOutput) -> String {
        switch finish.language {
        case "java": finish.output ? output.stdout : output.resultFile ?? ""
        case "clojure": output.stdout
        case "fortran": Tangle.removeIndentation(output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        default: Tangle.removeIndentation(output.stdout)
        }
    }

    /// `org-babel-result-cond` of the languages: a string as it is, or with `org-babel-read`
    /// for Fortran; else a table from the output (`org-babel-import-elisp-from-file`), or for
    /// Java and Clojure `org-babel-script-escape`.
    static func compiledValue(_ finish: BabelJob.Finish, _ output: BabelOutput, scalar: Bool) -> Value {
        let raw = compiledResult(finish, output)
        switch finish.language {
        case "java": return scalar ? .string(raw) : pythonValue(raw, none: "null", braces: true)
        case "clojure": return scalar ? .string(raw) : read(raw)
        case "fortran": return scalar ? read(raw) : importTable(raw)
        default: return scalar ? .string(raw) : importTable(raw)
        }
    }

    /// `org-babel-read` of printed output: a number, or a single string's contents; other
    /// values as printed. Clojure prints a final newline, so `org-babel-script-escape` never
    /// takes its output for a list.
    static func read(_ raw: String) -> Value {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = number(trimmed) { return .string(n) }
        if trimmed.hasPrefix("\""), let (sexp, length) = try? LispReader.readFirst(trimmed), length == trimmed.count, let s = sexp.string {
            return .string(s)
        }
        return .string(raw)
    }
}
