import Foundation

/// `#+SETUPFILE` (`org--collect-keywords-1`): each setup file's keywords count as if they were
/// in the file that names it, setup files named there included. Paths are relative to the
/// naming file's folder; URLs aren't fetched.
public enum SetupFile {
    /// The keyword lines the setup files `text` names bring, in order, as `#+KEY: value` lines.
    /// `read` gives a file's text, or nil when it can't be read.
    public static func keywordLines(in text: String, directory: String, read: (String) -> String?) -> String {
        lines(in: text, directory: directory, read: read, own: false, seen: [])
    }

    private static func lines(in text: String, directory: String, read: (String) -> String?, own: Bool, seen: Set<String>) -> String {
        guard own || text.range(of: "#+setupfile:", options: .caseInsensitive) != nil else { return "" }
        var out = ""
        for node in OrgParser.parse(text).root.descendants() where node.kind == .keyword {
            let line = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon].uppercased()
            guard key == "SETUPFILE" else {
                if own { out += line + "\n" }
                continue
            }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            guard !value.isEmpty, value.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) == nil else { continue }
            let expanded = (value as NSString).expandingTildeInPath
            let path = ((expanded.hasPrefix("/") ? expanded : (directory as NSString).appendingPathComponent(expanded)) as NSString).standardizingPath
            guard !seen.contains(path), let contents = read(path) else { continue }
            out += lines(in: contents, directory: (path as NSString).deletingLastPathComponent, read: read, own: true, seen: seen.union([path]))
        }
        return out
    }

    /// `(key, value)` for each `#+KEY: value` line.
    static func keywords(_ lines: String) -> [(key: String, value: Substring)] {
        lines.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("#+"), let colon = line.firstIndex(of: ":") else { return nil }
            return (line[line.index(line.startIndex, offsetBy: 2)..<colon].uppercased(), line[line.index(after: colon)...])
        }
    }
}

extension OrgSettings {
    /// These settings with the keywords of the setup files `text` names, for a file at `path`.
    public func resolvingSetupFiles(in text: String, path: String, read: (String) -> String?) -> OrgSettings {
        var copy = self
        copy.setupKeywords = SetupFile.keywordLines(in: text, directory: (path as NSString).deletingLastPathComponent, read: read)
        return copy
    }

    /// A file's text readable as UTF-8, for `resolvingSetupFiles`.
    public static func readFile(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
    }
}
