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

    /// The heading's start in `state`: its indexed offset if the file hasn't changed, else the
    /// first heading with the same title and level. Nil for the end of the file.
    func locate(in state: DocumentState) -> Int?? {
        guard let start else { return .some(nil) }
        if FileRecord.hash(state.mergeBase) == contentHash { return .some(start) }
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

/// The file open in a window: its buffer, outline, saving, and requests for the editor to
/// show a location. The view layer attaches the editor as the buffer and follows
/// `revealRequest`.
@MainActor
@Observable
public final class DocumentSession {
    public private(set) var path: String?
    /// A copy of the buffer's state as of its last change. Not observed: it changes on every
    /// keystroke; views follow `path`, `isDirty` and `outline`.
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
    public var lastError: String?
    public var saveMode: SaveMode = .automatic
    public var autosaveDelay: Duration = .seconds(1)
    /// Org options for commands the session runs (refile, archive).
    public var options: EditingOptions = .org
    /// TODO keywords and priorities for files without their own settings.
    public var defaults: OrgSettings = .default

    private let fileSystem: FileSystem
    private let recovery: RecoveryStore
    @ObservationIgnored private var buffer: DocumentBuffer?
    @ObservationIgnored var autosave: Task<Void, Never>?
    @ObservationIgnored private var outlineUpdate: Task<Void, Never>?
    private var requestID = 0

    public init(
        fileSystem: FileSystem = CoordinatedFileSystem(),
        recovery: RecoveryStore = FileRecoveryStore(directory: WorkspaceModel.defaultDirectory.appendingPathComponent("Recovery"))
    ) {
        self.fileSystem = fileSystem
        self.recovery = recovery
    }

    private var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    /// The caret in the open file.
    public var caret: Int { buffer?.selection.first?.lowerBound ?? 0 }
    private var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }

    public func open(_ path: String) {
        do {
            guard let bytes = try fileSystem.read(URL(fileURLWithPath: path)) else {
                lastError = "\((path as NSString).lastPathComponent) no longer exists."
                return
            }
            autosave?.cancel()
            self.path = path
            buffer = StateBuffer(DocumentState(bytes: bytes, defaults: defaults))
            conflict = nil
            revealRequest = nil
            refresh()
        } catch {
            lastError = "Can't open \(path): \(error.localizedDescription)"
        }
    }

    /// Makes `buffer`, built from `document`, the live state of the open file.
    public func attach(_ buffer: DocumentBuffer) {
        self.buffer = buffer
        refresh()
    }

    /// The buffer changed through typing. The outline follows once typing pauses.
    public func bufferChanged() {
        refresh(outline: false)
        outlineUpdate?.cancel()
        outlineUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let document = self.document else { return }
            self.outline = Presentation.outline(document.tree)
            self.editVersion += 1
        }
        scheduleAutosave()
    }

    private func refresh(outline updateOutline: Bool = true) {
        guard let buffer else { return }
        let state = buffer.document
        document = state
        if isDirty != state.isDirty { isDirty = state.isDirty }
        if isReadOnly == state.isEditable { isReadOnly = !state.isEditable }
        if updateOutline {
            outline = Presentation.outline(state.tree)
            editVersion += 1
        }
    }

    // MARK: - Saving

    private var saver: Saver { Saver(fileSystem: fileSystem, recovery: recovery) }

    private func scheduleAutosave() {
        autosave?.cancel()
        guard saveMode == .automatic, isDirty, conflict == nil else { return }
        autosave = Task { [weak self, autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Saves now. True when nothing is left unsaved.
    @discardableResult
    public func save() -> Bool {
        autosave?.cancel()
        guard let buffer, let url, isDirty else { return !isDirty }
        guard conflict == nil else { return false }
        do {
            let outcome = try buffer.update { try saver.save(&$0, to: url) }
            switch outcome {
            case .saved, .mergedAndSaved:
                break
            case .conflict:
                conflict = "\(name) changed on disk, and the changes conflict with yours."
            case .overwroteExternalChange(let change), .changedAfterWrite(let change):
                if case .conflict = change {
                    conflict = "\(name) changed on disk while saving, and the changes conflict with yours."
                }
            }
        } catch {
            lastError = "Can't save \(name): \(error.localizedDescription)"
        }
        refresh()
        return !isDirty
    }

    /// Resolves a conflict by writing the buffer over the disk version, which goes to recovery.
    public func keepMine() {
        guard let buffer, let url else { return }
        do {
            try buffer.update { try saver.overwrite(&$0, to: url) }
            conflict = nil
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
            conflict = nil
        } catch {
            lastError = "Can't read \(name): \(error.localizedDescription)"
        }
        refresh()
    }

    // MARK: - Moving subtrees

    /// The current context of the buffer, as commands see it.
    private func editContext(now: Date) -> EditContext? {
        guard let buffer else { return nil }
        let document = buffer.document
        return EditContext(revision: document.revision, text: document.text, tree: document.tree, selection: buffer.selection, now: now, options: options)
    }

    /// Moves the subtree at the caret under `target`. For another file, that file is written
    /// first, through the save path; the subtree leaves this buffer only once it has. Returns a
    /// message for the echo area.
    @discardableResult
    public func refile(to target: RefileTarget, now: Date = Date()) -> String? {
        guard let buffer, let path, let context = editContext(now: now) else { return nil }
        if target.path == path {
            let step = buffer.perform(RefileWithinFile(), now: now, answers: ["refile": target.start.map(String.init) ?? ""])
            if case .failed(let message) = step { return message }
            bufferChanged()
            return "Refiled to \(target.label)"
        }
        let url = URL(fileURLWithPath: target.path)
        do {
            guard let bytes = try fileSystem.read(url) else { return "\((target.path as NSString).lastPathComponent) no longer exists." }
            var state = DocumentState(bytes: bytes, defaults: defaults)
            guard state.isEditable else { return "\((target.path as NSString).lastPathComponent) isn't UTF-8, so it can't be changed." }
            guard let start = target.locate(in: state) else { return "Can't find \(target.label) any more." }
            guard let result = Refile.toOtherFile(source: context, target: state.text, under: start) else { return "Can't refile from here." }
            try state.apply([result.target], baseRevision: state.revision)
            if case .conflict = try saver.save(&state, to: url) { return "\((target.path as NSString).lastPathComponent) changed on disk; nothing was refiled." }
            if case .failed(let message) = buffer.perform(PrecomputedEdit(result.source), now: now, answers: [:]) { return message }
            bufferChanged()
            return "Refiled to \(target.label)"
        } catch {
            return "Can't refile: \(error.localizedDescription)"
        }
    }

    /// Archives the subtree at the caret where `org-archive-subtree` would. Returns a message.
    @discardableResult
    public func archive(now: Date = Date()) -> String? {
        guard let buffer, let path, let context = editContext(now: now) else { return nil }
        let destination: Archive.Destination
        switch Archive.destination(context, sourcePath: path) {
        case .success(let value): destination = value
        case .failure(.message(let message)): return message
        }
        do {
            let url = URL(fileURLWithPath: destination.path)
            let existing = destination.isSameFile ? nil : try fileSystem.read(url)
            var state = DocumentState(bytes: existing ?? [], defaults: defaults)
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
            if case .failed(let message) = buffer.perform(PrecomputedEdit(edits.source), now: now, answers: [:]) { return message }
            bufferChanged()
            return destination.isSameFile ? "Archived under \(destination.heading ?? "the end of the file")" : "Archived to \(url.lastPathComponent)"
        } catch {
            return "Can't archive: \(error.localizedDescription)"
        }
    }

    // MARK: - Commands from other views

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
        if path == self.path, let buffer {
            guard matches(buffer.document.text) else { return stale }
            do {
                let options = self.options
                let step = try buffer.update { try $0.run(command, selection: [offset..<offset], now: now, answers: answers, options: options) }
                if case .commit = step { bufferChanged() }
                return step
            } catch {
                return .failed("\(error)")
            }
        }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        do {
            guard let bytes = try fileSystem.read(url) else { return .failed("\(name) no longer exists.") }
            var state = DocumentState(bytes: bytes, defaults: defaults)
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
        guard let buffer, let path else { return "No file is open." }
        let snapshot = buffer.document.text as NSString
        guard table.upperBound <= snapshot.length else { return "The table moved; try again." }
        let old = snapshot.substring(with: NSRange(table))
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            let new = try await EmacsRunner.recalculateTable(text: snapshot as String, directory: directory, table: table, point: point, form: form)
            guard let current = self.buffer, self.path == path else { return "The file was closed before Emacs finished." }
            let text = current.document.text as NSString
            guard table.upperBound <= text.length, text.substring(with: NSRange(table)) == old else {
                return "The table changed while Emacs recalculated it; nothing was changed."
            }
            guard new != old else { return "Recalculated in Emacs" }
            let result = EditResult(baseRevision: current.document.revision, edits: [TextEdit(range: table, replacement: new)])
            if case .failed(let message) = current.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
            bufferChanged()
            return "Recalculated in Emacs"
        } catch {
            return "\(error)"
        }
    }

    /// Runs a src block and writes its result under it, unless the block changed while it
    /// ran. Returns a message for the echo area.
    public func runBabel(_ job: BabelJob) async -> String {
        guard let path, buffer != nil else { return "No file is open." }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            let output = try await BabelRunner.run(job, fileDirectory: directory)
            guard let current = self.buffer, self.path == path else { return "The file was closed before the block finished." }
            let document = current.document
            switch Babel.finish(job, output: output, text: document.text, settings: document.tree.settings) {
            case .failure(.message(let message)):
                return message
            case .success(let edits):
                guard !edits.isEmpty else { return job.finish.params.contains("silent") ? output.stdout : "Code block evaluation complete." }
                let result = EditResult(baseRevision: document.revision, edits: edits)
                if case .failed(let message) = current.perform(PrecomputedEdit(result), now: Date(), answers: [:]) { return message }
                bufferChanged()
                return "Code block evaluation complete."
            }
        } catch {
            return "\(error)"
        }
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

    /// Called when the workspace sees the open file change on disk.
    public func fileChanged(_ path: String) {
        guard path == self.path, let buffer, let bytes = try? fileSystem.read(URL(fileURLWithPath: path)) else { return }
        guard bytes != buffer.document.mergeBase else { return }
        switch buffer.update({ $0.diskChanged(to: bytes) }) {
        case .conflict:
            autosave?.cancel()
            conflict = "\(name) changed on disk, and the changes conflict with yours."
        case .merged, .reloaded:
            conflict = nil
        case .unchanged:
            break
        }
        refresh()
    }
}
