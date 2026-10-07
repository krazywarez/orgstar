import Foundation
import OrgIndex

public struct ReconcileReport: Sendable, Equatable {
    public var indexed: [String] = []
    public var touched: [String] = []
    public var moved: [String] = []
    public var removed: [String] = []
    public var unchanged = 0
    /// iCloud files asked to download; they are indexed once they arrive.
    public var placeholders: [URL] = []
}

/// Brings the index in line with the files under a root. File events are only hints, so this
/// is what runs at launch, after dropped events, and for every batch of changed paths.
public struct Reconciler: Sendable {
    public let index: IndexStore
    public let settings: IndexSettings
    public let rules: ScanRules

    public init(index: IndexStore, settings: IndexSettings, rules: ScanRules = ScanRules()) {
        self.index = index
        self.settings = settings
        self.rules = rules
    }

    /// Reconciles the whole root.
    public func reconcile(root: URL) throws -> ReconcileReport {
        let discovery = try WorkspaceScanner.scan(root, rules: rules)
        for placeholder in discovery.placeholders {
            try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
        }
        // Files iCloud evicted keep their rows until they're back.
        let pending = Set(discovery.placeholders.map(\.path))
        var report = try reconcile(root: root, found: discovery.files, known: index.fileStates(root: root.path).filter { !pending.contains($0.key) })
        report.placeholders = discovery.placeholders
        return report
    }

    /// Reconciles only `paths` under the root, for a batch of file events.
    public func reconcile(root: URL, paths: [URL]) throws -> ReconcileReport {
        let wanted = Set(paths.map(\.standardizedFileURL.path))
        let known = try index.fileStates(root: root.path).filter { wanted.contains($0.key) }
        var found: [DiscoveredFile] = []
        var placeholders: [URL] = []
        let rootComponents = root.standardizedFileURL.pathComponents.count
        for url in paths.map(\.standardizedFileURL) {
            // Files in ignored folders (`.git`) aren't part of the workspace, as in `scan`.
            if url.pathComponents.dropFirst(rootComponents).dropLast().contains(where: rules.skipsFolder) { continue }
            guard case .file(let kind) = WorkspaceScanner.classify(url.lastPathComponent, rules: rules),
                  let values = try? url.resourceValues(forKeys: Set(WorkspaceScanner.keys)),
                  values.isDirectory != true else { continue }
            if WorkspaceScanner.isPending(values) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                placeholders.append(url)
                continue
            }
            found.append(DiscoveredFile(
                url: url, kind: kind, size: values.fileSize ?? 0,
                mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        let pending = Set(placeholders.map(\.path))
        var report = try reconcile(root: root, found: found, known: known.filter { !pending.contains($0.key) })
        report.placeholders = placeholders
        return report
    }

    private func reconcile(root: URL, found: [DiscoveredFile], known: [String: FileState]) throws -> ReconcileReport {
        var report = ReconcileReport()
        var change = IndexChange()
        var candidates: [(file: DiscoveredFile, bytes: [UInt8], hash: String)] = []

        for file in found {
            let path = file.url.path
            if let state = known[path], state.size == file.size, state.mtime == file.mtime,
               state.settingsVersion == settings.version, state.kind == file.kind {
                report.unchanged += 1
                continue
            }
            if file.kind == .other {
                let record = FileRecord(path: path, root: root.path, unreadSize: file.size, mtime: file.mtime, settings: settings)
                if let state = known[path], state.hash == record.hash, state.settingsVersion == settings.version, state.kind == .other {
                    report.unchanged += 1
                } else {
                    candidates.append((file, [], record.hash))
                }
                continue
            }
            guard let data = try? Data(contentsOf: file.url) else { continue }
            let bytes = [UInt8](data)
            let hash = FileRecord.hash(bytes)
            if let state = known[path], state.hash == hash, state.settingsVersion == FileRecord.settingsVersion(settings, bytes: bytes, path: path),
               state.kind == file.kind {
                change.touches.append((path, file.mtime))
                report.touched.append(path)
            } else {
                candidates.append((file, bytes, hash))
            }
        }

        // A file that vanished and one that appeared with the same content is a rename.
        let foundPaths = Set(found.map(\.url.path))
        var missing = known.filter { !foundPaths.contains($0.key) }
        for candidate in candidates {
            let path = candidate.file.url.path
            if known[path] == nil,
               let (oldPath, _) = missing.first(where: {
                   $0.value.hash == candidate.hash && $0.value.kind == candidate.file.kind
                       && $0.value.settingsVersion == (candidate.file.kind == .other ? settings.version : FileRecord.settingsVersion(settings, bytes: candidate.bytes, path: path))
               }) {
                missing[oldPath] = nil
                change.moves.append((oldPath, path, candidate.file.mtime))
                report.moved.append(path)
            } else if candidate.file.kind == .other {
                change.records.append(FileRecord(path: path, root: root.path, unreadSize: candidate.file.size, mtime: candidate.file.mtime, settings: settings))
                report.indexed.append(path)
            } else {
                change.records.append(FileRecord(
                    path: path, root: root.path, kind: candidate.file.kind,
                    bytes: candidate.bytes, mtime: candidate.file.mtime, settings: settings
                ))
                report.indexed.append(path)
            }
        }
        change.removals = missing.keys.sorted()
        report.removed = change.removals
        try index.apply(change)
        return report
    }
}
