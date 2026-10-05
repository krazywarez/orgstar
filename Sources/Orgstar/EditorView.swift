import AppKit
import OrgApp
import OrgCore
import OrgEditorAppKit
import OrgHighlight
import SwiftUI

/// The TextKit 2 editor for the session's file. A new file gets a new editor, which becomes the
/// session's buffer; reveal requests go to the existing one.
struct EditorView: NSViewRepresentable {
    /// One highlighter for every editor: it caches compiled grammars and results.
    static let highlighter = TreeSitterHighlighter()

    let session: DocumentSession
    let commands: AppCommands
    let keymap: Keymap
    let modal: Bool
    let optionAsMeta: OptionAsMeta
    let options: EditingOptions
    let onAppCommand: (String) -> Void
    let onExternal: (ExternalRequest) -> Void

    final class Coordinator {
        var editor: OrgEditor?
        var path: String?
        var revealID = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.path != session.path {
            coordinator.path = session.path
            container.subviews.forEach { $0.removeFromSuperview() }
            coordinator.editor = nil
            if let document = session.document {
                let editor = OrgEditor(document: document, frame: container.bounds, editable: document.isEditable, highlighter: Self.highlighter)
                editor.onChange = { [weak session] in session?.bufferChanged() }
                editor.onMessage = { [weak commands] in commands?.show($0) }
                editor.onKeysPending = { [weak commands] keys, next in
                    commands?.pendingKeys = keys
                    commands?.keyHints = next.map { KeyHint(key: $0.key, title: $0.title) }
                }
                editor.onModeChange = { [weak commands] in commands?.editorState = $0 }
                editor.onAppCommand = onAppCommand
                editor.onExternal = onExternal
                editor.onPrompt = { [weak commands] prompt, reply in commands?.ask(prompt, reply: reply) }
                commands.editor = editor
                let scroll = editor.makeScrollView()
                scroll.frame = container.bounds
                scroll.autoresizingMask = [.width, .height]
                container.addSubview(scroll)
                container.window?.makeFirstResponder(editor.textView)
                coordinator.editor = editor
                session.attach(editor)
            }
        }
        if let editor = coordinator.editor {
            if editor.keymap != keymap { editor.keymap = keymap }
            editor.modal = modal
            editor.optionAsMeta = optionAsMeta
            editor.options = options
        }
        container.window?.isDocumentEdited = session.isDirty
        if let request = session.revealRequest, request.id != coordinator.revealID {
            coordinator.revealID = request.id
            coordinator.editor?.reveal(request.offset)
        }
    }
}
