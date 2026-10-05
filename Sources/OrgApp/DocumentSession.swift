import Foundation
import Observation
import OrgCore
import OrgDocument
import OrgIndex
import OrgPresentation

/// The file open in a window: its state, its outline, and requests for the editor to show a
/// location. The view layer owns the text view and follows `revealRequest` and `diskBytes`.
@MainActor
@Observable
public final class DocumentSession {
    public private(set) var path: String?
    public private(set) var document: DocumentState?
    public private(set) var outline: [OutlineEntry] = []
    /// Bumped to ask the editor to reveal an offset.
    public private(set) var revealRequest: (offset: Int, id: Int)?
    /// New bytes from disk for the open file, for the editor to merge or reload.
    public private(set) var diskBytes: (bytes: [UInt8], id: Int)?
    public var lastError: String?

    private let fileSystem: FileSystem
    private var requestID = 0

    public init(fileSystem: FileSystem = CoordinatedFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func open(_ path: String) {
        do {
            guard let bytes = try fileSystem.read(URL(fileURLWithPath: path)) else {
                lastError = "\((path as NSString).lastPathComponent) no longer exists."
                return
            }
            let document = DocumentState(bytes: bytes)
            self.path = path
            self.document = document
            outline = Presentation.outline(document.tree)
            revealRequest = nil
            diskBytes = nil
        } catch {
            lastError = "Can't open \(path): \(error.localizedDescription)"
        }
    }

    /// Opens the file of `location` if needed and asks the editor to show the heading. Offsets
    /// are used only if the file is unchanged since it was indexed; otherwise the heading is
    /// found again by position and title.
    public func show(_ location: HeadingLocation) {
        if path != location.path { open(location.path) }
        guard let document else { return }
        let hash = FileRecord.hash(document.mergeBase)
        let offset: Int
        if hash == location.contentHash {
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
        guard path == self.path, let bytes = try? fileSystem.read(URL(fileURLWithPath: path)) else { return }
        guard bytes != document?.mergeBase else { return }
        var updated = document ?? DocumentState(bytes: bytes)
        _ = updated.diskChanged(to: bytes)
        document = updated
        outline = Presentation.outline(updated.tree)
        requestID += 1
        diskBytes = (bytes, requestID)
    }
}
