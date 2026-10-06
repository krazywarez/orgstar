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
    /// An iCloud file on its way; it opens once it's indexed.
    public var isDownloading = false

    public var id: String { path }

    /// Folders first, then files, each by name. Conflict copies are listed with their files.
    public static func build(root: String, files: [FileEntry], downloading: [String] = []) -> FileTreeNode {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [FileEntry] = []
            var downloading: [String] = []
        }
        let top = Folder()
        for path in downloading where path.hasPrefix(root + "/") {
            var folder = top
            for component in path.dropFirst(root.count + 1).split(separator: "/").dropLast() {
                let name = String(component)
                if folder.folders[name] == nil { folder.folders[name] = Folder() }
                folder = folder.folders[name]!
            }
            folder.downloading.append(path)
        }
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
            let files = (folder.files.map {
                FileTreeNode(name: $0.name, path: $0.path, file: $0, children: nil)
            } + folder.downloading.map {
                FileTreeNode(name: ($0 as NSString).lastPathComponent, path: $0, file: nil, children: nil, isDownloading: true)
            }).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        let scored: [(file: FileEntry, score: Int)] = files.compactMap { file in score(query, file.relativePath).map { (file, $0) } }
        let ranked = scored.sorted { a, b in a.score != b.score ? a.score > b.score : a.file.relativePath < b.file.relativePath }
        return ranked.prefix(limit).map(\.file)
    }
}
