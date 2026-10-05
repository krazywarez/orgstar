import Foundation
import Observation
import OrgCore
import OrgDocument
import OrgIndex
import OrgPresentation

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
    public private(set) var isDirty = false
    /// Set while the buffer and the file on disk conflict; says how to resolve it.
    public private(set) var conflict: String?
    /// Bumped to ask the editor to reveal an offset.
    public private(set) var revealRequest: (offset: Int, id: Int)?
    public var lastError: String?
    public var saveMode: SaveMode = .automatic
    public var autosaveDelay: Duration = .seconds(1)

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
    private var name: String { path.map { ($0 as NSString).lastPathComponent } ?? "" }

    public func open(_ path: String) {
        do {
            guard let bytes = try fileSystem.read(URL(fileURLWithPath: path)) else {
                lastError = "\((path as NSString).lastPathComponent) no longer exists."
                return
            }
            autosave?.cancel()
            self.path = path
            buffer = StateBuffer(DocumentState(bytes: bytes))
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
        }
        scheduleAutosave()
    }

    private func refresh(outline updateOutline: Bool = true) {
        guard let buffer else { return }
        let state = buffer.document
        document = state
        if isDirty != state.isDirty { isDirty = state.isDirty }
        if updateOutline { outline = Presentation.outline(state.tree) }
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
