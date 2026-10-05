import Foundation
import OrgIndex

/// One file the workspace knows about.
public struct FileEntry: Sendable, Hashable, Identifiable {
    public let path: String
    public let root: String
    public let kind: FileKind

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// Path below the root, for display and agenda globs.
    public var relativePath: String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }
}

/// A folder or file in the sidebar.
public struct FileTreeNode: Sendable, Hashable, Identifiable {
    public let name: String
    /// The file's or folder's absolute path.
    public let path: String
    public let file: FileEntry?
    /// Nil for files, so a SwiftUI `OutlineGroup` shows no disclosure triangle.
    public let children: [FileTreeNode]?

    public var id: String { path }

    /// Folders first, then files, each by name. Conflict copies are listed with their files.
    public static func build(root: String, files: [FileEntry]) -> FileTreeNode {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [FileEntry] = []
        }
        let top = Folder()
        for file in files where file.root == root {
            var folder = top
            for component in file.relativePath.split(separator: "/").dropLast() {
                let name = String(component)
                if folder.folders[name] == nil { folder.folders[name] = Folder() }
                folder = folder.folders[name]!
            }
            folder.files.append(file)
        }
        func node(_ folder: Folder, name: String, path: String) -> FileTreeNode {
            let folders = folder.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
                node(folder.folders[$0]!, name: $0, path: path + "/" + $0)
            }
            let files = folder.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
                FileTreeNode(name: $0.name, path: $0.path, file: $0, children: nil)
            }
            return FileTreeNode(name: name, path: path, file: nil, children: folders + files)
        }
        return node(top, name: (root as NSString).lastPathComponent, path: root)
    }
}

/// Subsequence matching for quick open: every query character must appear in order. Matches
/// at word starts and runs of consecutive characters score higher; shorter names win ties.
public enum FuzzyMatch {
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let query = Array(query.lowercased().filter { !$0.isWhitespace })
        let text = Array(candidate.lowercased())
        guard !query.isEmpty else { return 0 }
        var score = 0
        var q = 0
        var previousMatch = -2
        for (i, c) in text.enumerated() where q < query.count && c == query[q] {
            score += 1
            if i == previousMatch + 1 { score += 5 }
            if i == 0 || "/ -_.".contains(text[i - 1]) { score += 8 }
            previousMatch = i
            q += 1
        }
        guard q == query.count else { return nil }
        return score * 100 - text.count
    }

    /// Entries ranked by `score` against their relative path, best first.
    public static func rank(_ query: String, _ files: [FileEntry], limit: Int = 50) -> [FileEntry] {
        files.compactMap { file in score(query, file.relativePath).map { (file, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.relativePath < $1.0.relativePath }
            .prefix(limit)
            .map(\.0)
    }
}
