#if os(iOS)
import CoreSpotlight
import Foundation
import OrgApp
import OrgCore
import UniformTypeIdentifiers

/// The workspace's org files in Spotlight with what the Mac's importer gives it: the text,
/// title, author, description, tags and headings. A file is indexed again when it changes.
@MainActor
final class SpotlightIndexer {
    private struct State: Codable {
        /// Also kept as the index's client state; the system deleting the index (as it does
        /// when the app is installed again) takes it away, and every file is indexed again.
        var generation = UUID()
        /// Modification dates of the files as indexed.
        var stamps: [String: Date] = [:]
    }

    private let index = CSSearchableIndex(name: "files")
    private let stateFile = WorkspaceModel.defaultDirectory.appendingPathComponent("spotlight.json")
    private var state: State
    /// Files to index once the running update finishes; a batch can't start while one is open.
    private var waiting: [FileEntry]?
    private var running = false

    init() {
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))) ?? State()
    }

    func update(_ files: [FileEntry]) async {
        let interval = Perf.begin("spotlight.update")
        defer { interval.end("\(files.count) files") }
        guard !running else { return waiting = files }
        running = true
        defer { running = false }
        var next: [FileEntry]? = files
        while let files = next {
            await index(files)
            next = waiting
            waiting = nil
        }
    }

    /// Opens a batch with the changes; `endBatch` commits them. Not async: in a batch the
    /// calls' completion handlers wait for the batch to end.
    private func submit(_ items: [CSSearchableItem], removing gone: [String]) {
        index.beginBatch()
        if !items.isEmpty { index.indexSearchableItems(items, completionHandler: nil) }
        if !gone.isEmpty { index.deleteSearchableItems(withIdentifiers: gone, completionHandler: nil) }
    }

    private func index(_ files: [FileEntry]) async {
        let generation = Data(state.generation.uuidString.utf8)
        let stamps = (try? await index.fetchLastClientState()) == generation ? state.stamps : [:]
        var current: [String: Date] = [:]
        var items: [CSSearchableItem] = []
        for file in files where file.kind == .org {
            guard let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { continue }
            if stamps[file.path] == date {
                current[file.path] = date
            } else if let text = try? String(contentsOfFile: file.path, encoding: .utf8) {
                items.append(Self.item(file, text: text))
                current[file.path] = date
            }
        }
        let gone = stamps.keys.filter { current[$0] == nil }
        guard !items.isEmpty || !gone.isEmpty else { return }
        submit(items, removing: gone)
        do {
            try await index.endBatch(withClientState: generation)
        } catch {
            return
        }
        state.stamps = current
        try? JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    }

    private static func item(_ file: FileEntry, text: String) -> CSSearchableItem {
        let summary = FileSummary(text)
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = summary.title ?? (file.name as NSString).deletingPathExtension
        attributes.displayName = attributes.title
        attributes.contentDescription = summary.description ?? file.relativePath
        attributes.textContent = text
        if let author = summary.author { attributes.authorNames = [author] }
        attributes.keywords = summary.tags + summary.headings
        return CSSearchableItem(uniqueIdentifier: file.path, domainIdentifier: "files", attributeSet: attributes)
    }
}
#endif
