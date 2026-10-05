import Foundation

/// The checked-out branch of the repository holding a file, read from `HEAD` without running
/// git.
public enum GitBranch {
    /// The branch name, the first 7 characters of the commit when HEAD is detached, or nil
    /// outside a repository.
    public static func current(for path: String) -> String? {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        while true {
            let dotGit = directory.appendingPathComponent(".git")
            if let head = head(dotGit) { return parse(head) }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// `HEAD` of a `.git` folder, or of the folder a `.git` file (worktree, submodule) names.
    static func head(_ dotGit: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        var gitDir = dotGit
        if !isDirectory.boolValue {
            guard let link = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = link.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
            let target = String(line.dropFirst("gitdir: ".count))
            gitDir = target.hasPrefix("/") ? URL(fileURLWithPath: target) : dotGit.deletingLastPathComponent().appendingPathComponent(target)
        }
        return try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
    }

    static func parse(_ head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: ") {
            let ref = line.dropFirst("ref: ".count)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
        }
        return line.isEmpty ? nil : String(line.prefix(7))
    }
}
