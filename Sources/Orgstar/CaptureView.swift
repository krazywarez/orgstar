import AppKit
import Carbon.HIToolbox
import OrgApp
import OrgCore
import SwiftUI

/// The capture window: pick a template by its key, answer its prompts, edit the entry, and
/// ⌘Return files it where the template says, as `org-capture` does.
struct CaptureView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    @State private var templates = CaptureTemplates.defaults
    @State private var problem: String?
    @State private var template: CaptureTemplate?
    @State private var questions: [Capture.Question] = []
    @State private var answers: [String] = []
    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var context = CaptureContext()
    @State private var editing = false
    @FocusState private var focused: Bool
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let template, editing {
                Text("\(template.name) → \(target(template))").font(.headline)
                TextEditor(text: $text, selection: $selection)
                    .font(.body.monospaced())
                    .focused($focused)
                    .frame(minHeight: 140)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("File It") { finish() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else if let template, !questions.isEmpty {
                Text(template.name).font(.headline)
                Form {
                    ForEach(questions.indices, id: \.self) { index in
                        TextField(questions[index].prompt, text: $answers[index], prompt: Text(questions[index].defaultValue))
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { close() }
                        .keyboardShortcut(.cancelAction)
                    Button("Continue") { expand() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Capture").font(.headline)
                ForEach(templates) { template in
                    Button {
                        choose(template)
                    } label: {
                        HStack {
                            Text("[\(template.key)]").monospaced().foregroundStyle(.secondary)
                            Text(template.name)
                            Spacer()
                            Text(target(template)).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }
        }
        .padding(16)
        .frame(width: 520)
        .onKeyPress(phases: .down) { press in
            guard template == nil, let match = templates.first(where: { $0.key == press.characters }) else { return .ignored }
            choose(match)
            return .handled
        }
        .onAppear(perform: reset)
    }

    private func target(_ template: CaptureTemplate) -> String {
        let file = (template.target.file as NSString).lastPathComponent
        switch template.target {
        case .file: return file
        case .headline(_, let headline): return "\(file) / \(headline)"
        case .outline(_, let path): return ([file] + path).joined(separator: " / ")
        }
    }

    private func reset() {
        let loaded = CaptureTemplates.load()
        templates = loaded.templates
        problem = loaded.problems.first
        template = nil
        editing = false
        context = CaptureContext(
            initial: commands.editor?.selectedText ?? "",
            annotation: session.captureAnnotation(),
            clipboard: NSPasteboard.general.string(forType: .string) ?? "",
            file: session.path ?? "",
            userName: NSFullUserName()
        )
    }

    private func choose(_ chosen: CaptureTemplate) {
        template = chosen
        questions = Capture.questions(chosen.template)
        answers = questions.map { _ in "" }
        if questions.isEmpty { expand() }
    }

    private func expand() {
        guard let template else { return }
        context.now = Date()
        switch Capture.fill(template.template, context: context, answers: answers) {
        case .failure(.message(let message)):
            problem = message
            self.template = nil
        case .success(let filled):
            text = filled.text
            let index = String.Index(utf16Offset: filled.cursor, in: text)
            selection = TextSelection(insertionPoint: index)
            editing = true
            focused = true
        }
    }

    private func finish() {
        guard let template else { return }
        if let message = session.capture(text, template: template, root: workspace.rootPaths.first) {
            problem = message
            return
        }
        commands.show("Captured to \(target(template))")
        close()
    }

    private func close() {
        reset()
        dismissWindow(id: "capture")
    }
}

/// A system-wide shortcut, registered with Carbon so it needs no accessibility permission.
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// ⌃⌥Space.
    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(data).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x4F52_4753), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
