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

/// Which files and folders a scan takes in.
public struct ScanRules: Sendable, Equatable {
    /// Dotfiles and dot folders, other than ignored folders.
    public var hiddenFiles: Bool
    /// Folder names never looked into: version control, caches, build output.
    public var ignoredFolders: Set<String>

    public static let defaultIgnoredFolders: Set<String> = [
        ".git", ".hg", ".svn", ".jj", ".bzr", ".stfolder", ".stversions", ".Trash", ".Spotlight-V100", ".fseventsd",
        ".build", ".venv", ".cache", ".tox", ".mypy_cache", ".pytest_cache", ".gradle", ".next", ".terraform", "node_modules",
    ]

    public init(hiddenFiles: Bool = true, ignoredFolders: Set<String> = defaultIgnoredFolders) {
        self.hiddenFiles = hiddenFiles
        self.ignoredFolders = ignoredFolders
    }

    public func skipsFolder(_ name: String) -> Bool {
        ignoredFolders.contains(name) || (!hiddenFiles && name.hasPrefix("."))
    }
}

public enum WorkspaceScanner {
    /// What a file name means to the workspace. Syncthing temp files, our own temp and backup
    /// files, Emacs backups, auto-saves and lock files, and Finder's files are ignored, and
    /// other dotfiles unless `rules` takes them in; files that aren't org files are `.other`.
    public static func classify(_ name: String, rules: ScanRules = ScanRules()) -> FileClassification {
        if name.hasPrefix(".") {
            if name.hasSuffix(".icloud") {
                let inner = String(name.dropFirst().dropLast(".icloud".count))
                if case .file = classify(inner, rules: rules) { return .placeholder(inner) }
                return .ignored
            }
            if !rules.hiddenFiles || name.hasPrefix(".#") || name.hasPrefix(".syncthing.") || name.contains(".orgstar-")
                || name == ".DS_Store" || name == ".localized" {
                return .ignored
            }
        }
        if name.hasSuffix("~") || name.hasPrefix("#") { return .ignored }
        let conflict = name.contains(".sync-conflict-")
        if name.hasSuffix(".org") { return .file(conflict ? .conflict : .org) }
        if name.hasSuffix(".org_archive") { return .file(conflict ? .conflict : .archive) }
        return .file(.other)
    }

    /// Resource keys a scan reads.
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    /// An iCloud file whose contents aren't on this device: reading it would wait for the
    /// download, so it's asked to download and indexed when it arrives. Since macOS 14 these
    /// keep their own names rather than `.name.icloud`.
    public static func isPending(isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        isUbiquitous == true && status == .notDownloaded
    }

    static func isPending(_ values: URLResourceValues) -> Bool {
        isPending(isUbiquitous: values.isUbiquitousItem, status: values.ubiquitousItemDownloadingStatus)
    }

    /// Every file under `root`, skipping the folders `rules` ignores.
    public static func scan(_ root: URL, rules: ScanRules = ScanRules()) throws -> Discovery {
        let keys = Self.keys
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return Discovery()
        }
        var discovery = Discovery()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values.isDirectory == true {
                if rules.skipsFolder(name) { enumerator.skipDescendants() }
                continue
            }
            switch classify(name, rules: rules) {
            case .file where isPending(values):
                discovery.placeholders.append(url.standardizedFileURL)
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
        // `org-agenda-file-regexp` leaves out dotfiles.
        guard kind == .org, !(relativePath as NSString).lastPathComponent.hasPrefix(".") else { return false }
        guard !globs.isEmpty else { return true }
        // Without FNM_PATHNAME, `*` also matches `/`, so `work/*` covers nested folders.
        return globs.contains { fnmatch($0, relativePath, 0) == 0 }
    }
}
