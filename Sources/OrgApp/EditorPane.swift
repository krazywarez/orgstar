import Foundation
import OrgCore
import OrgPresentation

/// One place a buffer shows, as a window shows a buffer in Emacs: which file, the buffers it
/// has shown (its tabs), and what the editor view in it follows. The session keeps these in
/// step with the buffers.
@MainActor
@Observable
public final class EditorPane: Identifiable {
    public let id = PaneID()
    /// The file shown, nil for an empty pane.
    public internal(set) var path: String?
    /// Open files this pane has shown, in the order it first showed them: its tabs.
    public internal(set) var shown: [String] = []
    /// Files this pane has shown, most recent first.
    public internal(set) var history: [String] = []
    public internal(set) var outline: [OutlineEntry] = []
    /// Bumped when the shown buffer settles after edits, and when a file opens here.
    public internal(set) var editVersion = 0
    public internal(set) var isDirty = false
    /// The file isn't UTF-8, so it can't be edited or saved.
    public internal(set) var isReadOnly = false
    /// Set while the shown buffer and the file on disk conflict; says how to resolve it.
    public internal(set) var conflict: String?
    /// Bumped to ask the editor in this pane to reveal an offset.
    public internal(set) var revealRequest: (offset: Int, id: Int)?

    public init() {}
}
