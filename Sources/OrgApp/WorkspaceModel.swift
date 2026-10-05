import Foundation
import Observation
import OrgDocument
import OrgPresentation
import OrgIndex
import OrgWorkspace

/// The folders the user added, the index over them, and the queries the window runs.
@MainActor
@Observable
public final class WorkspaceModel {
    public private(set) var roots: [WorkspaceRoot] = []
    public private(set) var files: [FileEntry] = []
    public private(set) var isIndexing = false
    /// The last error worth showing, such as a folder that can no longer be found.
    public var lastError: String?
    /// Bumped when an indexed file changes on disk, with its path.
    public private(set) var changedFile: (path: String, version: Int)?

    public let index: IndexStore
    public let settings: IndexSettings
    private let rootsFile: URL
    /// Resolved root folders, keyed by their resolved path, which is how the index stores them.
    private var resolvedRoots: [String: URL] = [:]
    @ObservationIgnored private var watcher: AnyObject?
    private var changeVersion = 0
    @ObservationIgnored private var overlayCache: (text: String, record: FileRecord)?

    /// `directory` holds the index and the list of roots; nil keeps both in memory.
    public init(directory: URL?, settings: IndexSettings = IndexSettings()) throws {
        self.settings = settings
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            index = try IndexStore(path: directory.appendingPathComponent("index.sqlite").path)
            rootsFile = directory.appendingPathComponent("roots.json")
        } else {
            index = try IndexStore()
            rootsFile = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-roots-\(UUID().uuidString).json")
        }
        if let data = try? Data(contentsOf: rootsFile), let saved = try? JSONDecoder().decode([WorkspaceRoot].self, from: data) {
            roots = saved
        }
        resolveRoots()
        try reloadFiles()
    }

    /// `~/Library/Application Support/Orgstar`, or `ORGSTAR_DATA_DIR` when set (for development).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["ORGSTAR_DATA_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Orgstar")
    }

    // MARK: - Roots

    public func addRoot(_ url: URL) async throws {
        let root = try WorkspaceRoot(url: url)
        guard !roots.contains(where: { $0.path == root.path }) else { return }
        roots.append(root)
        try saveRoots()
        resolveRoots()
        await refresh()
    }

    /// Removes a root by its resolved path, as `FileEntry.root` gives it.
    public func removeRoot(path: String) throws {
        let bookmarkPaths = roots.filter { (try? $0.resolve().url.path) == path || $0.path == path }.map(\.path)
        roots.removeAll { bookmarkPaths.contains($0.path) }
        try saveRoots()
        resolveRoots()
        var change = IndexChange()
        change.removals = files.filter { $0.root == path }.map(\.path)
        try index.apply(change)
        try reloadFiles()
    }

    private func saveRoots() throws {
        try JSONEncoder().encode(roots).write(to: rootsFile, options: .atomic)
    }

    /// Resolves bookmarks; refreshes stale ones; reports folders that can't be found.
    private func resolveRoots() {
        resolvedRoots = [:]
        var refreshed = roots
        for (i, root) in roots.enumerated() {
            guard let (url, isStale) = try? root.resolve() else {
                lastError = "Can't find the folder \(root.path)."
                continue
            }
            if isStale, let fresh = try? WorkspaceRoot(url: url) { refreshed[i] = fresh }
            resolvedRoots[url.path] = url
        }
        if refreshed != roots {
            roots = refreshed
            try? saveRoots()
        }
    }

    public func url(forRoot path: String) -> URL? { resolvedRoots[path] }

    /// Resolved root paths, sorted.
    public var rootPaths: [String] { resolvedRoots.keys.sorted() }

    // MARK: - Indexing

    /// Reconciles every root off the main thread, then reloads the file list.
    public func refresh() async {
        isIndexing = true
        defer { isIndexing = false }
        let reconciler = Reconciler(index: index, settings: settings)
        for url in resolvedRoots.values {
            do {
                _ = try await Task.detached { try reconciler.reconcile(root: url) }.value
            } catch {
                lastError = "Indexing \(url.path) failed: \(error.localizedDescription)"
            }
        }
        try? reloadFiles()
    }

    private func reloadFiles() throws {
        let roots = Set(resolvedRoots.keys)
        files = try index.files().compactMap { file in
            guard let root = roots.first(where: { file.path.hasPrefix($0 + "/") }) else { return nil }
            return FileEntry(path: file.path, root: root, kind: file.kind)
        }
    }

    /// Reconciles the paths a batch of file events named, or whole roots when events were lost.
    public func filesChanged(_ paths: [URL], rescan roots: [URL]) async {
        let reconciler = Reconciler(index: index, settings: settings)
        for rootURL in roots {
            _ = try? await Task.detached { try reconciler.reconcile(root: rootURL) }.value
        }
        for (rootPath, rootURL) in resolvedRoots where !roots.contains(rootURL) {
            let inRoot = paths.filter { $0.path.hasPrefix(rootPath + "/") }
            guard !inRoot.isEmpty else { continue }
            _ = try? await Task.detached { try reconciler.reconcile(root: rootURL, paths: inRoot) }.value
        }
        try? reloadFiles()
        for path in paths {
            changeVersion += 1
            changedFile = (path.standardizedFileURL.path, changeVersion)
        }
    }

    #if os(macOS)
    /// Watches every root; changes reconcile the index and are reported through `changedFile`.
    public func startWatching() {
        let roots = Array(resolvedRoots.values)
        guard !roots.isEmpty else { return }
        let fsWatcher = FSEventsWatcher(roots: roots.map { $0.resolvingSymlinksInPath() }) { [weak self] events in
            var changed: [URL] = []
            var rescans: [URL] = []
            for event in events {
                switch event {
                case .changed(let url): changed.append(url)
                case .rescan(let url): rescans.append(url)
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.filesChanged(changed.map(self.indexForm), rescan: rescans.compactMap(self.root(containing:)))
            }
        }
        fsWatcher.start()
        watcher = fsWatcher
    }
    #endif

    /// The root an event path belongs to.
    private func root(containing url: URL) -> URL? {
        resolvedRoots.values.first { url.path.hasPrefix($0.resolvingSymlinksInPath().path) || url.path.hasPrefix($0.path) }
    }

    /// FSEvents reports real paths (`/private/var/...`); the index uses the root's own form.
    func indexForm(_ url: URL) -> URL {
        for root in resolvedRoots.values {
            let real = root.resolvingSymlinksInPath().path
            if real != root.path, url.path.hasPrefix(real + "/") {
                return URL(fileURLWithPath: root.path + url.path.dropFirst(real.count))
            }
        }
        return url
    }

    // MARK: - Files

    public struct FileError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Creates an empty file at `name` (a name or a relative path; `.org` is added when it has
    /// no extension) inside `folder`, which must be in a root. Returns its path.
    public func createFile(named name: String, in folder: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.split(separator: "/").contains(where: { $0 == ".." }) else {
            throw FileError(message: "Not a file name: \(name)")
        }
        var url = URL(fileURLWithPath: folder).appendingPathComponent(trimmed)
        if url.pathExtension.isEmpty { url.appendPathExtension("org") }
        guard rootURL(containing: url.path) != nil else { throw FileError(message: "\(folder) isn't in a folder you added.") }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FileError(message: "\(url.lastPathComponent) already exists.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
        await rescan(containing: url.path)
        return url.standardizedFileURL.path
    }

    /// Renames a file or folder in place. Returns the new path.
    public func rename(_ path: String, to name: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != ".", trimmed != ".." else {
            throw FileError(message: "Not a file name: \(name)")
        }
        let target = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(trimmed)
        guard target.path != path else { return path }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw FileError(message: "\(trimmed) already exists.") }
        try FileManager.default.moveItem(atPath: path, toPath: target.path)
        await rescan(containing: path)
        return target.standardizedFileURL.path
    }

    /// How `trash` disposes of a file; tests replace it so nothing reaches the real Trash.
    @ObservationIgnored public var trasher: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Moves a file or folder to the Trash.
    public func trash(_ path: String) async throws {
        try trasher(URL(fileURLWithPath: path))
        await rescan(containing: path)
    }

    private func rootURL(containing path: String) -> URL? {
        resolvedRoots.first { path == $0.key || path.hasPrefix($0.key + "/") }?.value
    }

    /// Brings the index up to date for the root holding `path` now, rather than when the
    /// file events arrive.
    private func rescan(containing path: String) async {
        guard let root = rootURL(containing: path) else { return }
        await filesChanged([], rescan: [root])
    }

    // MARK: - Queries

    public func tree(forRoot path: String) -> FileTreeNode {
        FileTreeNode.build(root: path, files: files)
    }

    public func search(_ query: String, overlay: [String: FileRecord] = [:]) -> [HeadingLocation] {
        (try? index.search(query, overlay: overlay)) ?? []
    }

    /// Index rows for an open file's unsaved text, keyed by path, for queries to use in place
    /// of its rows on disk. Empty when the file has no unsaved edits. Cached until the text
    /// changes.
    public func overlay(path: String?, document: DocumentState?) -> [String: FileRecord] {
        guard let path, let document, document.isDirty, let bytes = try? document.encodedText(),
              let entry = files.first(where: { $0.path == path }) else { return [:] }
        if let cached = overlayCache, cached.record.path == path, cached.text == document.text {
            return [path: cached.record]
        }
        let record = FileRecord(path: path, root: entry.root, kind: entry.kind, bytes: bytes, mtime: Date().timeIntervalSince1970, settings: settings)
        overlayCache = (document.text, record)
        return [path: record]
    }

    /// Headings down to level 3 in every org file, and each file itself. The open file's come
    /// from its buffer, so they match unsaved edits.
    public func refileTargets(openPath: String?, document: DocumentState?) -> [RefileTarget] {
        let indexed = (try? index.outline(maxLevel: 3)) ?? []
        var targets: [RefileTarget] = []
        for file in files where file.kind == .org {
            let name = file.relativePath
            if file.path == openPath, let document {
                let hash = FileRecord.hash(document.mergeBase)
                targets.append(RefileTarget(label: name, path: file.path, start: nil, title: "", level: 0, contentHash: hash))
                var stack: [String] = []
                for entry in Presentation.outline(document.tree) {
                    stack = Array(stack.prefix(entry.level - 1)) + [entry.title]
                    guard entry.level <= 3 else { continue }
                    targets.append(RefileTarget(label: name + "/" + stack.joined(separator: "/"), path: file.path, start: entry.start, title: entry.title, level: entry.level, contentHash: hash))
                }
                continue
            }
            let headings = indexed.filter { $0.location.path == file.path }
            targets.append(RefileTarget(label: name, path: file.path, start: nil, title: "", level: 0, contentHash: headings.first?.location.contentHash ?? ""))
            for heading in headings {
                targets.append(RefileTarget(
                    label: name + "/" + heading.outlinePath.joined(separator: "/"), path: file.path, start: heading.location.start,
                    title: heading.location.title, level: heading.level, contentHash: heading.location.contentHash
                ))
            }
        }
        return targets
    }

    public func quickOpen(_ query: String) -> [FileEntry] {
        FuzzyMatch.rank(query, files.filter { $0.kind != .conflict })
    }
}
