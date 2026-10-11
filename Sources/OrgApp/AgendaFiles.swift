import Foundation

/// `org-agenda-files` as the `(org-agenda-files)` function reads it: each entry a folder (its
/// `.org` files not starting with a dot, in name order, not below it), an `.org` file, or a
/// file listing more entries one per line, as the variable's string form names one.
/// Relative paths count from `base`, standing in for `org-directory`. Missing files are left out.
public enum AgendaFiles {
    public static func resolve(_ entries: [String], base: String?, fileManager: FileManager = .default) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        func expand(_ entry: String, from base: String?) -> String {
            let path = (entry as NSString).expandingTildeInPath
            if path.hasPrefix("/") || base == nil { return (path as NSString).standardizingPath }
            return ((base! as NSString).appendingPathComponent(path) as NSString).standardizingPath
        }
        func add(_ path: String) {
            if seen.insert(path).inserted { out.append(path) }
        }
        func visit(_ entry: String, listed: Bool) {
            let path = expand(entry, from: base)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
            if isDirectory.boolValue {
                let names = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
                for name in names.sorted() where !name.hasPrefix(".") && name.hasSuffix(".org") {
                    let file = (path as NSString).appendingPathComponent(name)
                    var dir: ObjCBool = false
                    if fileManager.fileExists(atPath: file, isDirectory: &dir), !dir.boolValue { add(file) }
                }
            } else if path.hasSuffix(".org") || listed {
                add(path)
            } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                // `org-read-agenda-file-list`.
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { visit(trimmed, listed: true) }
                }
            }
        }
        for entry in entries { visit(entry, listed: false) }
        return out
    }
}
