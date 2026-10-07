import Foundation
import Observation
import OrgCore
import OrgDocument
import OrgIndex
import OrgPresentation

/// A heading, or a whole file, a subtree can be refiled to.
public struct RefileTarget: Sendable, Hashable {
    /// `file.org/Parent/Heading`, as the prompt lists it.
    public let label: String
    public let path: String
    /// Start of the heading when the file had `contentHash`; nil refiles to the end of the file.
    public let start: Int?
    public let title: String
    public let level: Int
    public let contentHash: String

    public init(label: String, path: String, start: Int?, title: String, level: Int, contentHash: String) {
        self.label = label
        self.path = path
        self.start = start
        self.title = title
        self.level = level
        self.contentHash = contentHash
    }

    /// The heading's start in `state`: its indexed offset if the text is what was indexed,
    /// else the first heading with the same title and level. Nil for the end of the file.
    func locate(in state: DocumentState) -> Int?? {
        guard let start else { return .some(nil) }
        if !state.isDirty, FileRecord.hash(state.mergeBase) == contentHash { return .some(start) }
        let entry = Presentation.outline(state.tree).first { $0.title == title && $0.level == level }
        return entry.map { .some($0.start) }
    }
}

public enum SaveMode: String, Sendable, CaseIterable {
    /// Save shortly after typing stops.
    case automatic
    /// Save only on ⌘S.
    case explicit
}

/// The files open in a window, as Emacs's buffers: each keeps its text, caret, undo and
/// unsaved edits while another is shown. The current buffer's outline, saving and requests
/// for the editor to show a location are what most views use. The view layer attaches an
/// editor to each buffer and follows `path` and `revealRequest`.
@MainActor
@Observable
public final class DocumentSession {
    /// The current buffer's file.
    public private(set) var path: String?
    /// A copy of the current buffer's state as of its last change. Not observed: it changes
    /// on every keystroke; views follow `path`, `isDirty` and `outline`.
    @ObservationIgnored public private(set) var document: DocumentState?
    public private(set) var outline: [OutlineEntry] = []
    /// Bumped when the buffer settles after edits, and when a file opens: views that read
    /// `document` follow this.
    public private(set) var editVersion = 0
    public private(set) var isDirty = false
    /// The file isn't UTF-8, so it can't be edited or saved.
    public private(set) var isReadOnly = false
    /// Set while the buffer and the file on disk conflict; says how to resolve it.
    public private(set) var conflict: String?
    /// Bumped to ask the editor to reveal an offset.
    public private(set) var revealRequest: (offset: Int, id: Int)?
    /// Open files, in the order buffers were opened (each after the one current then).
    public private(set) var openPaths: [String] = []
    /// Open files with unsaved edits.
    public private(set) var dirtyPaths: Set<String> = []
    public var lastError: String?
    public var saveMode: SaveMode = .automatic
    public var autosaveDelay: Duration = .seconds(1)
    /// Org options for commands the session runs (refile, archive).
    public var options: EditingOptions = .org
    /// TODO keywords and priorities for files without their own settings.
    public var defaults: OrgSettings = .default

    /// A buffer for `bytes` read from `path`, with the keywords of the setup files it names.
    func loaded(_ bytes: [UInt8], path: String) -> DocumentState {
        DocumentState(bytes: bytes, defaults: defaults.resolvingSetupFiles(in: SourceText(bytes: bytes).text, path: path, read: readText))
    }

    /// A file's text, for setup files.
    func readText(_ file: String) -> String? {
        (try? fileSystem.read(URL(fileURLWithPath: file))).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// C-c C-c on a keyword line: the open file's setup files read again (`org-mode-restart`).
    public func refreshSetup() {
        guard let entry = current else { return }
        let settings = defaults.resolvingSetupFiles(in: entry.buffer.document.text, path: entry.path, read: readText)
        entry.buffer.update { $0.setDefaults(settings) }
        refresh()
        editVersion += 1
    }

    /// One open file.
    @MainActor
    final class Entry {
        let path: String
        var buffer: DocumentBuffer
        var conflict: String?
        var autosave: Task<Void, Never>?

        init(path: String, buffer: DocumentBuffer) {
            self.path = path
            self.buffer = buffer
        }
    }

    private let fileSystem: FileSystem
    private let recovery: RecoveryStore
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var current: Entry?
    /// Paths, most recently shown first.
    @ObservationIgnored private var history: [String] = []
    @ObservationIgnored private var outlineUpdate: Task<Void, Never>?
    private var requestID = 0

    public init(
        fileSystem: FileSystem = CoordinatedFileSystem(),
        recovery: RecoveryStore = FileRecoveryStore(directory: WorkspaceModel.defaultDirectory.appendingPathComponent("Recovery"))
    ) {
        self.fileSystem = fileSystem
        self.recovery = recovery
    }

    private var buffer: DocumentBuffer? { current?.buffer }
    /// The current buffer's pending autosave, for tests to wait on.
    var autosave: Task<Void, Never>? { current?.autosave }
    private var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    /// Whether the open file is an org file (`.org`, `.org_archive`), not plain text.
    public var isOrg: Bool { path.map(Self.isOrgPath) ?? false }

    public static func isOrgPath(_ path: String) -> Bool {
        path.hasSuffix(".org") || path.hasSuffix(".org_archive")
    }

    /// The caret in the open file.
    public var caret: Int { buffer?.selection.first?.lowerBound ?? 0 }
    private var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }

    private func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    public func isOpen(_ path: String) -> Bool { entry(path) != nil }

    /// The caret of an open file.
    public func caret(of path: String) -> Int? { entry(path)?.buffer.selection.first?.lowerBound }

    /// The text of every open file, for views that read files (the agenda, search).
    public var openDocuments: [(path: String, document: DocumentState)] {
        entries.map { ($0.path, $0.buffer.document) }
    }

    /// The text of every open file by path, for the agenda.
    public var openTexts: [String: String] {
        Dictionary(entries.map { ($0.path, $0.buffer.document.text) }, uniquingKeysWith: { a, _ in a })
    }

    /// Open buffers, most recently shown first.
    public var recentPaths: [String] { history.filter(isOpen) }

    /// Shows the buffer of `path`, opening the file if it isn't open.
    public func open(_ path: String) {
        if let existing = entry(path) {
            activate(existing)
            return
        }
        do {
            guard let bytes = try fileSystem.read(URL(fileURLWithPath: path)) else {
                lastError = "\((path as NSString).lastPathComponent) no longer exists."
                return
            }
            let entry = Entry(path: path, buffer: StateBuffer(loaded(bytes, path: path)))
            let index = current.flatMap { c in entries.firstIndex { $0 === c } }.map { $0 + 1 } ?? entries.count
            entries.insert(entry, at: index)
            activate(entry)
        } catch {
            lastError = "Can't open \(path): \(error.localizedDescription)"
        }
    }

    private func activate(_ entry: Entry) {
        current = entry
        path = entry.path
        conflict = entry.conflict
        revealRequest = nil
        history.removeAll { $0 == entry.path }
        history.insert(entry.path, at: 0)
        refresh()
    }

    /// The buffer before or after the current one, wrapping.
    public func cycle(_ step: Int) {
        guard let current, let index = entries.firstIndex(where: { $0 === current }), entries.count > 1 else { return }
        activate(entries[((index + step) % entries.count + entries.count) % entries.count])
    }

    /// The buffer shown before the current one.
    public func showPrevious() {
        guard let previous = recentPaths.dropFirst().first else { return }
        open(previous)
    }

    /// Closes the buffer of `path` without saving it; the most recent other buffer shows.
    public func kill(_ path: String) {
        guard let entry = entry(path) else { return }
        entry.autosave?.cancel()
        entries.removeAll { $0 === entry }
        history.removeAll { $0 == path }
        if entry === current {
            current = nil
            if let next = recentPaths.first.flatMap(self.entry) ?? entries.last {
                activate(next)
            } else {
                outlineUpdate?.cancel()
                self.path = nil
                document = nil
                outline = []
                isDirty = false
                conflict = nil
                revealRequest = nil
                refreshLists()
            }
        } else {
            refreshLists()
        }
    }

    /// Closes the current buffer without saving, as when its file was deleted.
    public func close() {
        if let path { kill(path) }
    }

    /// Makes `buffer`, built from `document`, the live state of the current file.
    public func attach(_ buffer: DocumentBuffer) {
        current?.buffer = buffer
        refresh()
    }

    /// The buffer of `path` changed in its editor: the current one updates its views, another
    /// saves on its own.
    public func bufferChanged(_ path: String) {
        guard let entry = entry(path) else { return }
        if entry === current { bufferChanged() } else { scheduleAutosave(entry); refreshLists() }
    }

    /// The buffer changed through typing. The outline follows once typing pauses.
    public func bufferChanged() {
        refresh(outline: false)
        outlineUpdate?.cancel()
        outlineUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let document = self.document else { return }
            self.outline = self.isOrg ? Presentation.outline(document.tree) : []
            self.editVersion += 1
        }
        if let current { scheduleAutosave(current) }
    }

    private func refresh(outline updateOutline: Bool = true) {
        refreshLists()
        guard let buffer else { return }
        let state = buffer.document
        document = state
        if isDirty != state.isDirty { isDirty = state.isDirty }
        if isReadOnly == state.isEditable { isReadOnly = !state.isEditable }
        if conflict != current?.conflict { conflict = current?.conflict }
        if updateOutline {
            outline = isOrg ? Presentation.outline(state.tree) : []
            editVersion += 1
        }
    }

    private func refreshLists() {
        let paths = entries.map(\.path)
        if paths != openPaths { openPaths = paths }
        let dirty = Set(entries.filter { $0.buffer.document.isDirty }.map(\.path))
        if dirty != dirtyPaths { dirtyPaths = dirty }
    }

    // MARK: - Saving

    private var saver: Saver { Saver(fileSystem: fileSystem, recovery: recovery) }

    private func scheduleAutosave(_ entry: Entry) {
        entry.autosave?.cancel()
        guard saveMode == .automatic, entry.buffer.document.isDirty, entry.conflict == nil else { return }
        entry.autosave = Task { [weak self, weak entry, autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled, let self, let entry else { return }
            self.save(entry)
        }
    }

    /// Saves the current buffer now. True when nothing is left unsaved.
    @discardableResult
    public func save() -> Bool {
        guard let current else { return true }
        return save(current)
    }

    /// Saves the buffer of `path`. True when nothing is left unsaved.
    @discardableResult
    public func save(_ path: String) -> Bool {
        guard let entry = entry(path) else { return true }
        return save(entry)
    }

    /// Saves every open buffer. True when nothing is left unsaved.
    @discardableResult
    public func saveAll() -> Bool {
        entries.map { save($0) }.allSatisfy { $0 }
    }

    @discardableResult
    private func save(_ entry: Entry) -> Bool {
        entry.autosave?.cancel()
        let name = (entry.path as NSString).lastPathComponent
        guard entry.buffer.document.isDirty else { return true }
        guard entry.conflict == nil else { return false }
        do {
            let outcome = try entry.buffer.update { try saver.save(&$0, to: URL(fileURLWithPath: entry.path)) }
            switch outcome {
            case .saved, .mergedAndSaved:
                break
            case .conflict:
                entry.conflict = "\(name) changed on disk, and the changes conflict with yours."
            case .overwroteExternalChange(let change), .changedAfterWrite(let change):
                if case .conflict = change {
                    entry.conflict = "\(name) changed on disk while saving, and the changes conflict with yours."
                }
            }
        } catch {
            lastError = "Can't save \(name): \(error.localizedDescription)"
        }
        if entry === current { refresh() } else { refreshLists() }
        return !entry.buffer.document.isDirty
    }

    /// Resolves a conflict by writing the buffer over the disk version, which goes to recovery.
    public func keepMine() {
        guard let buffer, let url else { return }
        do {
            try buffer.update { try saver.overwrite(&$0, to: url) }
            current?.conflict = nil
        } catch {
            lastError = "Can't save \(name): \(error.localizedDescription)"
        }
        refresh()
    }

    /// Resolves a conflict by loading the disk version; the buffer goes to recovery.
    public func useDiskVersion() {
        guard let buffer, let url else { return }
        do {
            guard let bytes = try fileSystem.read(url) else { return }
            if isDirty { try recovery.keep(try buffer.document.encodedText(), for: url, label: "local") }
            buffer.update { $0 = DocumentState(bytes: bytes, defaults: $0.defaults) }
            current?.conflict = nil
        } catch {
            lastError = "Can't read \(name): \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Comparing versions

    /// The buffer, the file on disk and the version both started from, while they conflict.
    public func conflictVersions() -> (mine: String, disk: String, base: String)? {
        guard current?.conflict != nil, let buffer, let url, let disk = try? fileSystem.read(url) else { return nil }
        return (buffer.document.text, SourceText(bytes: disk).text, SourceText(bytes: buffer.document.mergeBase).text)
    }

    /// Resolves a conflict as `git merge` leaves one: the buffer holds both sides' changes, those
    /// that conflict between markers, to fix and save. The disk version becomes the base, and
    /// the buffer as it was goes to recovery.
    public func mergeConflictWithMarkers() {
        guard let versions = conflictVersions(), let buffer, let url, let disk = try? fileSystem.read(url) else { return }
        do {
            try recovery.keep(try buffer.document.encodedText(), for: url, label: "local")
            let merged = mergeWithMarkers(base: versions.base, ours: versions.mine, theirs: versions.disk, oursLabel: "yours", theirsLabel: "disk")
            try buffer.update { state in
                state = DocumentState(bytes: disk, defaults: state.defaults)
                try state.apply(lineEdits(from: versions.disk, to: merged), baseRevision: state.revision)
            }
            current?.conflict = nil
        } catch {
            lastError = "Can't merge \(name): \(error.localizedDescription)"
        }
        refresh()
    }

    /// Syncthing's conflict copies of the open file beside it: `name.sync-conflict-DATE-TIME-ID.ext`.
    public func syncConflictCopies() -> [URL] {
        guard let url else { return [] }
        let folder = url.deletingLastPathComponent()
        let stem = NSRegularExpression.escapedPattern(for: url.deletingPathExtension().lastPathComponent)
        let ext = url.pathExtension.isEmpty ? "" : "\\." + NSRegularExpression.escapedPattern(for: url.pathExtension)
        let pattern = "^" + stem + "\\.sync-conflict-[0-9]{8}-[0-9]{6}-[A-Z0-9]+" + ext + "$"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.range(of: pattern, options: .regularExpression) != nil }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// What to do with a conflict copy: keep the file as it is, take the copy's text, or merge
    /// the two with markers. The copy goes to recovery and is removed.
    public enum CopyResolution { case keepFile, useCopy, merge }

    public func resolve(copy: URL, _ resolution: CopyResolution) -> String? {
        guard let buffer, let url else { return "No file is open" }
        do {
            guard let bytes = try fileSystem.read(copy) else { return "\(copy.lastPathComponent) is gone" }
            let copyText = SourceText(bytes: bytes).text
            let mine = buffer.document.text
            let new: String? = switch resolution {
            case .keepFile: nil
            case .useCopy: copyText
            case .merge: mergeWithMarkers(base: nil, ours: mine, theirs: copyText, oursLabel: url.lastPathComponent, theirsLabel: copy.lastPathComponent)
            }
            if let new, new != mine {
                let result = EditResult(baseRevision: buffer.document.revision, edits: lineEdits(from: mine, to: new))
                if case .failed(let message) = buffer.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
            }
            try recovery.keep(bytes, for: url, label: "sync-conflict")
            try FileManager.default.removeItem(at: copy)
        } catch {
            return "Can't resolve \(copy.lastPathComponent): \(error.localizedDescription)"
        }
        if let current { changed(current) }
        return nil
    }

    /// Versions of the open file kept in recovery, newest first, with when and why each was
    /// kept.
    public func recoveryVersions() -> [(url: URL, date: Date, label: String)] {
        guard let url, let store = recovery as? FileRecoveryStore, let versions = try? store.versions(for: url) else { return [] }
        // `STAMP-LABEL-UUID8-NAME`, as `FileRecoveryStore.keep` names them.
        return versions.reversed().map { version in
            let m = version.lastPathComponent.firstMatch(of: /^([0-9]+)-(.+?)-([0-9A-Fa-f]{8})-/)
            let nanos = m.flatMap { UInt64($0.1) } ?? 0
            return (version, Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000), m.map { String($0.2) } ?? "")
        }
    }

    /// The text of a kept version.
    public func recoveryText(_ version: URL) -> String? {
        (try? fileSystem.read(version)).flatMap { $0 }.map { SourceText(bytes: $0).text }
    }

    /// Puts a kept version's text in the buffer, as an edit that can be undone; the buffer as it
    /// was goes to recovery.
    public func restore(_ version: URL) -> String? {
        guard let buffer, let url, let text = recoveryText(version) else { return "Can't read that version" }
        do {
            try recovery.keep(try buffer.document.encodedText(), for: url, label: "local")
        } catch {
            return "Can't keep the current version: \(error.localizedDescription)"
        }
        let mine = buffer.document.text
        let result = EditResult(baseRevision: buffer.document.revision, edits: lineEdits(from: mine, to: text))
        if case .failed(let message) = buffer.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
        if let current { changed(current) }
        return nil
    }

    // MARK: - Moving subtrees

    /// The current context of the buffer, as commands see it.
    private func editContext(now: Date) -> EditContext? {
        guard let buffer else { return nil }
        let document = buffer.document
        return EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: buffer.selection, now: now, options: options)
    }

    /// The file and context a subtree command works on: `from` (a file and a heading in it,
    /// as the agenda gives them), or the current buffer at its caret.
    private func source(_ from: (path: String, offset: Int)?, now: Date) -> (path: String, context: EditContext)? {
        guard let from else {
            guard let path, let context = editContext(now: now) else { return nil }
            return (path, context)
        }
        let state: DocumentState
        if let open = entry(from.path) {
            state = open.buffer.document
        } else {
            guard let bytes = try? fileSystem.read(URL(fileURLWithPath: from.path)) else { return nil }
            state = loaded(bytes, path: from.path)
        }
        guard state.isEditable else { return nil }
        let context = EditContext(revision: state.revision, text: state.text, tree: state.tree, selection: [from.offset..<from.offset], now: now, options: options)
        return (from.path, context)
    }

    /// Applies an edit computed from `source(_:now:)` to that file, open or not.
    private func applySource(_ edit: EditResult, path: String, now: Date) -> String? {
        if case .failed(let message) = perform(PrecomputedEdit(edit), path: path, at: 0, expect: nil, now: now) { return message }
        return nil
    }

    /// Moves the subtree at the caret, or at `from`, under `target`. For another file, that
    /// file is written first, through the save path; the subtree leaves its file only once it
    /// has. Returns a message for the echo area.
    @discardableResult
    public func refile(to target: RefileTarget, from: (path: String, offset: Int)? = nil, now: Date = Date()) -> String? {
        guard let (path, context) = source(from, now: now) else { return from == nil ? nil : "Can't read the entry's file." }
        if target.path == path {
            let answers = ["refile": target.start.map(String.init) ?? ""]
            let step = from == nil ? buffer?.perform(RefileWithinFile(), now: now, answers: answers)
                : perform(RefileWithinFile(), path: path, at: from!.offset, expect: nil, answers: answers, now: now)
            if case .failed(let message)? = step { return message }
            if from == nil { bufferChanged() }
            return "Refiled to \(target.label)"
        }
        let url = URL(fileURLWithPath: target.path)
        let targetName = (target.path as NSString).lastPathComponent
        // A target open in a buffer takes the subtree there, with its unsaved edits.
        if let open = entry(target.path) {
            let state = open.buffer.document
            guard state.isEditable else { return "\(targetName) isn't UTF-8, so it can't be changed." }
            guard let start = target.locate(in: state) else { return "Can't find \(target.label) any more." }
            guard let result = Refile.toOtherFile(source: context, target: state.text, under: start) else { return "Can't refile from here." }
            let edit = EditResult(baseRevision: state.revision, edits: [result.target])
            if case .failed(let message) = open.buffer.perform(PrecomputedEdit(edit), now: now, answers: [:]) { return message }
            changed(open)
            if let message = applySource(result.source, path: path, now: now) { return message }
            return "Refiled to \(target.label)"
        }
        do {
            guard let bytes = try fileSystem.read(url) else { return "\(targetName) no longer exists." }
            var state = loaded(bytes, path: url.path)
            guard state.isEditable else { return "\(targetName) isn't UTF-8, so it can't be changed." }
            guard let start = target.locate(in: state) else { return "Can't find \(target.label) any more." }
            guard let result = Refile.toOtherFile(source: context, target: state.text, under: start) else { return "Can't refile from here." }
            try state.apply([result.target], baseRevision: state.revision)
            if case .conflict = try saver.save(&state, to: url) { return "\(targetName) changed on disk; nothing was refiled." }
            if let message = applySource(result.source, path: path, now: now) { return message }
            return "Refiled to \(target.label)"
        } catch {
            return "Can't refile: \(error.localizedDescription)"
        }
    }

    /// Archives the subtree at the caret, or at `from`, where `org-archive-subtree` would.
    /// Returns a message.
    @discardableResult
    public func archive(from: (path: String, offset: Int)? = nil, now: Date = Date()) -> String? {
        guard let (path, context) = source(from, now: now) else { return from == nil ? nil : "Can't read the entry's file." }
        let destination: Archive.Destination
        switch Archive.destination(context, sourcePath: path) {
        case .success(let value): destination = value
        case .failure(.message(let message)): return message
        }
        // An archive file open in a buffer takes the subtree there.
        if !destination.isSameFile, let open = entry(destination.path) {
            let state = open.buffer.document
            let name = (destination.path as NSString).lastPathComponent
            guard state.isEditable else { return "\(name) isn't UTF-8, so it can't be changed." }
            let edits: Archive.Edits
            switch Archive.run(context, sourcePath: path, destination: destination, archiveText: state.text) {
            case .success(let value): edits = value
            case .failure(.message(let message)): return message
            }
            if let archiveEdit = edits.archive {
                let edit = EditResult(baseRevision: state.revision, edits: [archiveEdit])
                if case .failed(let message) = open.buffer.perform(PrecomputedEdit(edit), now: now, answers: [:]) { return message }
                changed(open)
            }
            if let message = applySource(edits.source, path: path, now: now) { return message }
            return "Archived to \(name)"
        }
        do {
            let url = URL(fileURLWithPath: destination.path)
            let existing = destination.isSameFile ? nil : try fileSystem.read(url)
            var state = loaded(existing ?? [], path: url.path)
            if !destination.isSameFile, !state.isEditable { return "\(url.lastPathComponent) isn't UTF-8, so it can't be changed." }
            let edits: Archive.Edits
            switch Archive.run(context, sourcePath: path, destination: destination, archiveText: existing.map { _ in state.text }) {
            case .success(let value): edits = value
            case .failure(.message(let message)): return message
            }
            if let archiveEdit = edits.archive {
                try state.apply([archiveEdit], baseRevision: state.revision)
                if case .conflict = try saver.save(&state, to: url) { return "\(url.lastPathComponent) changed on disk; nothing was archived." }
            }
            if let message = applySource(edits.source, path: path, now: now) { return message }
            return destination.isSameFile ? "Archived under \(destination.heading ?? "the end of the file")" : "Archived to \(url.lastPathComponent)"
        } catch {
            return "Can't archive: \(error.localizedDescription)"
        }
    }

    // MARK: - Commands from other views

    /// Where the heading line `line` is now in `path`: at `offset` if it still reads so, else
    /// the copy of the line nearest `offset`. For acting on agenda entries after other edits
    /// moved them.
    public func locateHeading(path: String, line: String, near offset: Int) -> Int? {
        guard let text = entry(path)?.buffer.document.text ?? (try? fileSystem.read(URL(fileURLWithPath: path))).flatMap({ $0.map { SourceText(bytes: $0).text } }) else { return nil }
        let ns = text as NSString
        let length = (line as NSString).length
        if offset + length <= ns.length, ns.substring(with: NSRange(location: offset, length: length)) == line,
           offset == 0 || ns.character(at: offset - 1) == 10 {
            return offset
        }
        var best: Int?
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: line, options: [], range: search)
            guard found.location != NSNotFound else { break }
            let atLineStart = found.location == 0 || ns.character(at: found.location - 1) == 10
            let lineEnd = NSMaxRange(found) == ns.length || ns.character(at: NSMaxRange(found)) == 10
            if atLineStart, lineEnd, best.map({ abs($0 - offset) > abs(found.location - offset) }) ?? true { best = found.location }
            search = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
        }
        return best
    }

    /// Runs `command` with the caret at `offset` in the file at `path`, as the agenda does:
    /// through the buffer when the file is open, leaving its caret alone; otherwise on the
    /// file, written back at once through the save path. `expect` is the heading line the
    /// caller saw at a position; if the text there changed, nothing runs.
    public func perform(
        _ command: any OrgCommand, path: String, at offset: Int, expect: (start: Int, line: String)?,
        answers: [String: String] = [:], now: Date = Date()
    ) -> CommandStep {
        let stale = CommandStep.failed("The entry changed; the agenda has been refreshed.")
        func matches(_ text: String) -> Bool {
            guard let expect else { return true }
            let ns = text as NSString
            guard expect.start + (expect.line as NSString).length <= ns.length else { return false }
            return ns.substring(with: NSRange(location: expect.start, length: (expect.line as NSString).length)) == expect.line
        }
        if let entry = entry(path) {
            let buffer = entry.buffer
            guard matches(buffer.document.text) else { return stale }
            do {
                let options = self.options
                let step = try buffer.update { try $0.run(command, selection: [offset..<offset], now: now, answers: answers, options: options) }
                if case .commit = step {
                    if entry === current { bufferChanged() } else { scheduleAutosave(entry); refreshLists() }
                }
                return step
            } catch {
                return .failed("\(error)")
            }
        }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        do {
            guard let bytes = try fileSystem.read(url) else { return .failed("\(name) no longer exists.") }
            var state = loaded(bytes, path: path)
            guard state.isEditable else { return .failed("\(name) isn't UTF-8, so it can't be changed.") }
            guard matches(state.text) else { return stale }
            let step = try state.run(command, selection: [offset..<offset], now: now, answers: answers, options: options)
            if case .commit = step, state.isDirty, case .conflict = try saver.save(&state, to: url) {
                return .failed("\(name) changed on disk; nothing was changed.")
            }
            return step
        } catch {
            return .failed("Can't change \(name): \(error.localizedDescription)")
        }
    }

    // MARK: - External work

    /// Recalculates a table in Emacs from a snapshot of the buffer, then replaces the table
    /// with Emacs's text if it hasn't changed meanwhile. Returns a message for the echo area.
    public func recalculateInEmacs(table: Range<Int>, point: Int, form: String) async -> String {
        #if os(macOS)
        guard let entry = current else { return "No file is open." }
        let path = entry.path
        let snapshot = entry.buffer.document.text as NSString
        guard table.upperBound <= snapshot.length else { return "The table moved; try again." }
        let old = snapshot.substring(with: NSRange(table))
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            let new = try await EmacsRunner.recalculateTable(text: snapshot as String, directory: directory, table: table, point: point, form: form)
            guard entries.contains(where: { $0 === entry }) else { return "The file was closed before Emacs finished." }
            let current = entry.buffer
            let text = current.document.text as NSString
            guard table.upperBound <= text.length, text.substring(with: NSRange(table)) == old else {
                return "The table changed while Emacs recalculated it; nothing was changed."
            }
            guard new != old else { return "Recalculated in Emacs" }
            let result = EditResult(baseRevision: current.document.revision, edits: [TextEdit(range: table, replacement: new)])
            if case .failed(let message) = current.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
            changed(entry)
            return "Recalculated in Emacs"
        } catch {
            return "\(error)"
        }
        #else
        return "Tables that need Emacs aren't recalculated on iOS."
        #endif
    }

    /// Runs a src block and writes its result under it, unless the block changed while it
    /// ran. Returns a message for the echo area.
    public func runBabel(_ job: BabelJob) async -> String {
        guard let entry = current else { return "No file is open." }
        let directory = URL(fileURLWithPath: entry.path).deletingLastPathComponent()
        /// A program on the Mac; on iOS, Emacs Lisp in `Elisp`, and nothing else.
        func run(_ job: BabelJob) async throws -> BabelOutput {
            #if os(macOS)
            return try await BabelRunner.run(job, fileDirectory: directory)
            #else
            guard let output = try Babel.evaluateNatively(job) else {
                throw Babel.Failure.message(job.lispForm == nil
                    ? "\(job.language) blocks need the Mac to run."
                    : "This block uses Emacs Lisp that runs only in Emacs, on the Mac.")
            }
            return output
            #endif
        }
        do {
            // Blocks the `:var`s refer to run first, one at a time.
            var job = job
            while let need = job.needs.first {
                let output = try await run(need.job)
                guard entries.contains(where: { $0 === entry }) else { return "The file was closed before the block finished." }
                let document = entry.buffer.document
                switch Babel.resume(job, need: need, output: output, text: document.text, tree: document.tree) {
                case .failure(.message(let message)): return message
                case .success(let next): job = next
                }
            }
            let output = try await run(job)
            guard entries.contains(where: { $0 === entry }) else { return "The file was closed before the block finished." }
            if let file = Babel.fileResult(job, output: output) {
                let runDirectory = job.directory.map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL } ?? directory
                let target = file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path) : runDirectory.appendingPathComponent(file.path)
                do {
                    try file.contents.write(to: target, atomically: true, encoding: .utf8)
                } catch {
                    return "Can't write \(file.path): \(error.localizedDescription)"
                }
            }
            let current = entry.buffer
            let document = current.document
            let done = output.problem ?? "Code block evaluation complete."
            switch Babel.finish(job, output: output, text: document.text, settings: document.tree.settings) {
            case .failure(.message(let message)):
                return message
            case .success(let edits):
                guard !edits.isEmpty else { return job.finish.params.contains("silent") ? output.problem ?? output.stdout : done }
                let result = EditResult(baseRevision: document.revision, edits: edits)
                if case .failed(let message) = current.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
                changed(entry)
                return done
            }
        } catch is CancellationError {
            return "Code block canceled."
        } catch Babel.Failure.message(let message) {
            return message
        } catch {
            return "\(error)"
        }
    }

    /// The block running now, to cancel.
    @ObservationIgnored private var babelTask: Task<String, Never>?
    public private(set) var isRunningBabel = false

    /// Runs a src block in the background; its message comes back through `report`.
    public func startBabel(_ job: BabelJob, report: @escaping @MainActor (String) -> Void) {
        babelTask?.cancel()
        isRunningBabel = true
        let task = Task { await runBabel(job) }
        babelTask = task
        Task {
            let message = await task.value
            if babelTask == task {
                babelTask = nil
                isRunningBabel = false
            }
            report(message)
        }
    }

    /// Stops the running block; its results aren't inserted.
    public func cancelBabel() {
        babelTask?.cancel()
    }

    /// A buffer changed outside typing: the current one updates its views, another saves.
    private func changed(_ entry: Entry) {
        if entry === current { bufferChanged() } else { scheduleAutosave(entry); refreshLists() }
    }

    // MARK: - Locations

    /// Opens the file of `location` if needed and asks the editor to show the heading. Offsets
    /// are used only if the buffer matches what was indexed; otherwise the heading is found
    /// again by position and title.
    public func show(_ location: HeadingLocation) {
        if path != location.path { open(location.path) }
        guard let document else { return }
        let hash = FileRecord.hash(document.mergeBase)
        let offset: Int
        if !isDirty, hash == location.contentHash {
            offset = location.start
        } else if location.ordinal < outline.count, outline[location.ordinal].title == location.title {
            offset = outline[location.ordinal].start
        } else if let entry = outline.first(where: { $0.title == location.title }) {
            offset = entry.start
        } else {
            return
        }
        reveal(offset)
    }

    public func reveal(_ offset: Int) {
        requestID += 1
        revealRequest = (offset, requestID)
    }

    /// Called when the workspace sees a file change on disk: an open buffer of it takes the
    /// change in.
    public func fileChanged(_ path: String) {
        guard let entry = entry(path), let bytes = try? fileSystem.read(URL(fileURLWithPath: path)) else { return }
        let buffer = entry.buffer
        guard bytes != buffer.document.mergeBase else { return }
        let name = (path as NSString).lastPathComponent
        switch buffer.update({ $0.diskChanged(to: bytes) }) {
        case .conflict:
            entry.autosave?.cancel()
            entry.conflict = "\(name) changed on disk, and the changes conflict with yours."
        case .merged, .reloaded:
            entry.conflict = nil
            // Edits merged with the disk's still need saving.
            scheduleAutosave(entry)
        case .unchanged:
            break
        }
        if entry === current { refresh() } else { refreshLists() }
    }
}
