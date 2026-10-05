import AppKit
import OrgApp
import OrgEditorAppKit
import SwiftUI

/// The read-only TextKit 2 editor for the session's file. A new file gets a new editor; reveal
/// requests and changes on disk go to the existing one, so folds survive a reload.
struct EditorView: NSViewRepresentable {
    let session: DocumentSession

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
                let editor = OrgEditor(document: document, frame: container.bounds, editable: false)
                let scroll = editor.makeScrollView()
                scroll.frame = container.bounds
                scroll.autoresizingMask = [.width, .height]
                container.addSubview(scroll)
                container.window?.makeFirstResponder(editor.textView)
                coordinator.editor = editor
                session.attach(editor)
            }
        }
        if let request = session.revealRequest, request.id != coordinator.revealID {
            coordinator.revealID = request.id
            coordinator.editor?.reveal(request.offset)
        }
    }
}
