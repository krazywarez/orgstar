import AppKit
import OrgApp
import OrgCore
import OrgEditorAppKit
import OrgPresentation
import OrgHighlight
import SwiftUI

/// The TextKit 2 editors for the session's buffers: one per open file, kept while another
/// shows so its caret, folds and undo stay. An editor becomes its buffer's live state; reveal
/// requests go to the one showing.
struct EditorView: NSViewRepresentable {
    /// One highlighter for every editor: it caches compiled grammars and results.
    static let highlighter = TreeSitterHighlighter()

    let session: DocumentSession
    let commands: AppCommands
    let keymap: Keymap
    let modal: Bool
    let optionAsMeta: OptionAsMeta
    let options: EditingOptions
    let showMarkup: Bool
    let showLineNumbers: Bool
    let theme: ThemeSpec
    let onAppCommand: (String) -> Void
    let onExternal: (ExternalRequest) -> Void
    let knownTags: @Sendable () -> [String]

    final class Coordinator {
        var editor: OrgEditor?
        var path: String?
        var revealID = 0
        /// Editors of open buffers, with their scroll views.
        var editors: [String: (editor: OrgEditor, scroll: NSScrollView)] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        // Buffers that were killed take their editors with them.
        for path in coordinator.editors.keys where !session.openPaths.contains(path) {
            coordinator.editors[path]?.scroll.removeFromSuperview()
            coordinator.editors[path] = nil
        }
        if coordinator.path != session.path {
            coordinator.path = session.path
            container.subviews.forEach { $0.removeFromSuperview() }
            coordinator.editor = nil
            if let path = session.path, let shown = coordinator.editors[path] ?? makeEditor(container) {
                coordinator.editors[path] = shown
                shown.scroll.frame = container.bounds
                container.addSubview(shown.scroll)
                container.window?.makeFirstResponder(shown.editor.textView)
                coordinator.editor = shown.editor
                commands.editor = shown.editor
                session.attach(shown.editor)
            } else {
                commands.editor = nil
            }
        }
        if let editor = coordinator.editor {
            if editor.keymap != keymap { editor.keymap = keymap }
            editor.modal = modal
            editor.optionAsMeta = optionAsMeta
            editor.options = options
            editor.showMarkup = showMarkup
            editor.showLineNumbers = showLineNumbers
            editor.themeSpec = theme
        }
        container.window?.isDocumentEdited = !session.dirtyPaths.isEmpty
        if let request = session.revealRequest, request.id != coordinator.revealID {
            coordinator.revealID = request.id
            coordinator.editor?.reveal(request.offset)
        }
    }

    /// An editor for the current buffer, which becomes the buffer's live state.
    private func makeEditor(_ container: NSView) -> (editor: OrgEditor, scroll: NSScrollView)? {
        guard let document = session.document else { return nil }
        let mode: OrgEditor.Mode = session.isOrg ? .org : .plain(language: session.path.flatMap(FileTypes.language))
        let editor = OrgEditor(document: document, frame: container.bounds, editable: document.isEditable, highlighter: Self.highlighter, mode: mode, options: options)
        let path = session.path ?? ""
        editor.onChange = { [weak session] in session?.bufferChanged(path) }
        if !path.isEmpty { editor.baseDirectory = URL(fileURLWithPath: path).deletingLastPathComponent() }
        editor.onMessage = { [weak commands] in commands?.show($0) }
        editor.onKeysPending = { [weak commands] keys, next in
            commands?.pendingKeys = keys
            commands?.keyHints = next.map { KeyHint(key: $0.key, title: $0.title) }
        }
        editor.onModeChange = { [weak commands] in commands?.editorState = $0 }
        editor.onSelectionChange = { [weak commands] in commands?.selection = $0 }
        editor.onAppCommand = onAppCommand
        editor.onExternal = onExternal
        editor.knownTags = knownTags
        editor.onPrompt = { [weak commands] prompt, reply in commands?.ask(prompt, reply: reply) }
        editor.onEffect = { [weak commands] effect in
            switch effect {
            case .storedLinkUsed(let link): commands?.storedLinks.removeAll { $0.link == link }
            case .copy(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .message, .sparseTree, .fold: break
            }
        }
        let scroll = editor.makeScrollView()
        scroll.autoresizingMask = [.width, .height]
        return (editor, scroll)
    }
}
