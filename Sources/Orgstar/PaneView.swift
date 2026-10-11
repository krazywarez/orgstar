import AppKit
import OrgApp
import OrgCore
import OrgEditorAppKit
import OrgPresentation
import OrgHighlight
import SwiftUI

/// What every editor view is set up with, from the settings.
struct EditorSettings: Equatable {
    var keymap = KeymapPreset.emacs.keymap
    var modal = false
    var optionAsMeta = OptionAsMeta.left
    var options = EditingOptions.org
    var showMarkup = false
    var showLineNumbers = true
    var lineNumbersType = LineNumbersType.absolute
    var theme = ThemeSpec.default
}

/// One pane's editor: the text view of the buffer the pane shows, from the store, which keeps
/// one editor per open file and one text view per pane showing it. A new editor becomes its
/// buffer's live state; the pane's reveal requests go to its text view.
struct PaneView: NSViewRepresentable {
    /// One highlighter for every editor: it caches compiled grammars and results.
    static let highlighter = TreeSitterHighlighter()

    let pane: EditorPane
    let session: DocumentSession
    let commands: AppCommands
    let settings: EditorSettings
    let onAppCommand: (String) -> Void

    final class Coordinator {
        var path: String?
        var textView: NSTextView?
        var revealID = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        let store = commands.store
        if coordinator.path != pane.path {
            coordinator.path = pane.path
            container.subviews.forEach { $0.removeFromSuperview() }
            coordinator.textView = nil
            if let path = pane.path, let shown = store.view(for: pane, path: path, make: { makeEditor(path, container) }) {
                shown.scroll.frame = container.bounds
                container.addSubview(shown.scroll)
                coordinator.textView = shown.textView
                if session.focused === pane {
                    container.window?.makeFirstResponder(shown.textView)
                    commands.editor = shown.editor
                }
            } else if session.focused === pane {
                commands.editor = nil
            }
        }
        if let path = pane.path, let editor = store.editor(for: path) {
            if editor.keymap != settings.keymap { editor.keymap = settings.keymap }
            editor.modal = settings.modal
            editor.optionAsMeta = settings.optionAsMeta
            // `buffer-file-name`, for clock tables.
            var options = settings.options
            options.filePath = path
            if editor.options != options { editor.options = options }
            editor.showMarkup = settings.showMarkup
            editor.showLineNumbers = settings.showLineNumbers
            editor.lineNumbersType = settings.lineNumbersType
            editor.themeSpec = settings.theme
        }
        container.window?.isDocumentEdited = !session.dirtyPaths.isEmpty
        if let request = pane.revealRequest, request.id != coordinator.revealID, let textView = coordinator.textView, let path = pane.path, let editor = store.editor(for: path) {
            coordinator.revealID = request.id
            // The editor reveals in its active view: this pane's, once it has focus.
            textView.window?.makeFirstResponder(textView)
            editor.reveal(request.offset)
        }
    }

    /// An editor for `path`, which becomes the buffer's live state.
    private func makeEditor(_ path: String, _ container: NSView) -> OrgEditor? {
        guard let entry = session.openDocuments.first(where: { $0.path == path }) else { return nil }
        let document = entry.document
        let mode: OrgEditor.Mode = DocumentSession.isOrgPath(path) ? .org : .plain(language: FileTypes.language(path))
        let editor = OrgEditor(document: document, frame: container.bounds, editable: document.isEditable, highlighter: Self.highlighter, mode: mode, options: settings.options)
        let store = commands.store
        editor.onChange = { [weak session] in session?.bufferChanged(path) }
        editor.baseDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
        editor.attachmentPath = { DocumentSession.attachmentPath($0, at: $1, tree: $2, path: path) }
        editor.onMessage = { [weak commands] in commands?.show($0) }
        editor.onKeysPending = { [weak commands] keys, next in
            commands?.pendingKeys = keys
            commands?.keyHints = next.map { KeyHint(key: $0.key, title: $0.title) }
        }
        editor.onModeChange = { [weak commands] in commands?.editorState = $0 }
        editor.onSelectionChange = { [weak commands] in commands?.selection = $0 }
        editor.onFocus = { [weak session, weak commands, weak editor] textView in
            guard let session, let commands, let editor else { return }
            commands.editor = editor
            if let pane = store.pane(of: textView) {
                session.focused = pane
                store.window(of: pane.id)?.focused = pane.id
            }
        }
        editor.onAppCommand = onAppCommand
        editor.onOpenFile = { [weak session, weak commands] typed in
            let expanded = (typed as NSString).expandingTildeInPath
            let base = URL(fileURLWithPath: path).deletingLastPathComponent()
            let target = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: target) else {
                commands?.show("No file \(typed)")
                return
            }
            session?.open(target)
        }
        editor.onJumpToEditor = { [weak session] other, offset in
            guard let session, let path = store.editors.first(where: { $0.value === other })?.key else { return }
            session.open(path)
            session.reveal(offset)
        }
        editor.onExternal = { [weak commands] request in commands?.externalHandler?(request) }
        editor.knownTags = { [weak commands] in MainActor.assumeIsolated { commands?.knownTags() ?? [] } }
        editor.onPrompt = { [weak commands] prompt, reply in commands?.ask(prompt, reply: reply) }
        editor.onEffect = { [weak commands, weak session] effect in
            switch effect {
            case .storedLinkUsed(let link): commands?.storedLinks.removeAll { $0.link == link }
            case .copy(let text):
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case .refreshSetup: session?.refreshSetup()
            case .timer(let timer): TimerModel.shared.set(timer)
            case .message, .sparseTree, .fold: break
            }
        }
        session.attach(editor, for: path)
        return editor
    }
}
