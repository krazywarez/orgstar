import Foundation

extension Babel {
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
}
