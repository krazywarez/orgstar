import AppKit
import OrgCore
import OrgDocument
import OrgEditorAppKit
import SwiftUI

/// `org-edit-special` for a block: its text in an editor of its own, highlighted as its
/// language. ⌘Return or C-c ' puts it back; Escape or C-c C-k leaves it.
struct BlockEditorView: View {
    let edit: BlockEdit
    let finish: (String?) -> Void
    @State private var box = EditorBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(edit.title)
                .font(.headline)
            CodeEditor(text: edit.content, language: edit.language, box: box) { save in finish(save ? box.text : nil) }
                .frame(minWidth: 560, minHeight: 320)
                .border(.separator)
            HStack {
                Text("C-c ' or ⌘Return saves, Escape or C-c C-k leaves").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(edit.kind == "field" ? "Save Field" : "Save Block") { finish(box.text) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(16)
    }
}

/// Holds the editor so the view can read its text when saving.
@MainActor
final class EditorBox {
    var editor: OrgEditor?
    var text: String { editor?.document.text ?? "" }
}

/// An `OrgEditor` in plain mode for the block's language.
struct CodeEditor: NSViewRepresentable {
    let text: String
    let language: String?
    let box: EditorBox
    let done: (Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let editor = OrgEditor(document: DocumentState(bytes: [UInt8](text.utf8)), highlighter: EditorView.highlighter, mode: .plain(language: language))
        editor.keymap = Keymap([
            KeyBinding(keys: KeySequence.parse("C-c '")!, command: "app.block.save"),
            KeyBinding(keys: KeySequence.parse("C-c C-k")!, command: "app.block.cancel"),
        ])
        editor.onAppCommand = { id in
            if id == "app.block.save" { done(true) }
            if id == "app.block.cancel" { done(false) }
        }
        box.editor = editor
        let scroll = editor.makeScrollView()
        DispatchQueue.main.async { scroll.window?.makeFirstResponder(editor.textView) }
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}
