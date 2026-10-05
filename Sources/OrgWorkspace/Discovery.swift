import Foundation
import OrgIndex

/// A folder the user added. Identified by its bookmark, so a moved folder is followed.
public struct WorkspaceRoot: Sendable, Equatable, Codable {
    public let bookmark: Data
    /// The path when the bookmark was made or last refreshed, for display.
    public var path: String

    public init(url: URL) throws {
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        path = url.standardizedFileURL.path
    }

    /// The folder's current location. `isStale` means the bookmark should be made again.
    public func resolve() throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        _ = url.startAccessingSecurityScopedResource()
        return (url.standardizedFileURL, isStale)
    }
}

public struct DiscoveredFile: Sendable, Equatable {
    public let url: URL
    public let kind: FileKind
    public let size: Int
    public let mtime: Double
}

public struct Discovery: Sendable, Equatable {
    public var files: [DiscoveredFile] = []
    /// iCloud files not downloaded yet, by the name they will have.
    public var placeholders: [URL] = []
}

public enum FileClassification: Sendable, Equatable {
    case file(FileKind)
    /// An iCloud placeholder (`.name.org.icloud`) for the file at the given name.
    case placeholder(String)
    case ignored
}

public enum WorkspaceScanner {
    /// What a file name means to the workspace. Syncthing temp files, our own temp and backup
    /// files, Emacs backups and auto-saves, and other hidden files are ignored.
    public static func classify(_ name: String) -> FileClassification {
        if name.hasPrefix(".") {
            if name.hasSuffix(".icloud") {
                let inner = String(name.dropFirst().dropLast(".icloud".count))
                if case .file = classify(inner) { return .placeholder(inner) }
            }
            return .ignored
        }
        if name.hasSuffix("~") || name.hasPrefix("#") { return .ignored }
        let conflict = name.contains(".sync-conflict-")
        if name.hasSuffix(".org") { return .file(conflict ? .conflict : .org) }
        if name.hasSuffix(".org_archive") { return .file(conflict ? .conflict : .archive) }
        return .ignored
    }

    /// Every org file under `root`, skipping hidden folders (`.git`, `.stfolder`, `.stversions`).
    public static func scan(_ root: URL) throws -> Discovery {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return Discovery()
        }
        var discovery = Discovery()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values.isDirectory == true {
                if name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            switch classify(name) {
            case .file(let kind):
                discovery.files.append(DiscoveredFile(
                    url: url.standardizedFileURL,
                    kind: kind,
                    size: values.fileSize ?? 0,
                    mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                ))
            case .placeholder(let inner):
                discovery.placeholders.append(url.deletingLastPathComponent().appendingPathComponent(inner).standardizedFileURL)
            case .ignored:
                break
            }
        }
        discovery.files.sort { $0.url.path < $1.url.path }
        return discovery
    }
}

/// Which files feed the agenda: `.org` files (not archives or conflict copies) matching one of
/// the globs, relative to their root. No globs means every `.org` file.
public struct AgendaScope: Sendable, Equatable {
    public var globs: [String]

    public init(globs: [String] = []) {
        self.globs = globs
    }

    public func contains(relativePath: String, kind: FileKind) -> Bool {
        guard kind == .org else { return false }
        guard !globs.isEmpty else { return true }
        // Without FNM_PATHNAME, `*` also matches `/`, so `work/*` covers nested folders.
        return globs.contains { fnmatch($0, relativePath, 0) == 0 }
    }
}
