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
    let clock: ClockModel
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
        case .file, .heading: return file
        case .headline(_, let headline): return "\(file) / \(headline)"
        case .outline(_, let path): return ([file] + path).joined(separator: " / ")
        case .datetree(_, let path, _): return ([file] + path + ["date tree"]).joined(separator: " / ")
        case .id(let id): return "ID \(id)"
        case .clock: return "clocked entry"
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
            if template.options.immediateFinish {
                finish()
                return
            }
            let index = String.Index(utf16Offset: filled.cursor, in: text)
            selection = TextSelection(insertionPoint: index)
            editing = true
            focused = true
        }
    }

    /// `id` and `clock` targets as a file and a heading.
    private func resolved(_ template: CaptureTemplate) -> Result<(template: CaptureTemplate, file: String?), CaptureError> {
        switch template.target {
        case .id(let id):
            guard let location = try? workspace.index.headings(withID: id).first else {
                return .failure(CaptureError(message: "Cannot find target ID \"\(id)\""))
            }
            return .success((template, location.path))
        case .clock:
            guard let entry = clock.entry(session) else { return .failure(CaptureError(message: "No running clock")) }
            return .success((template.retargeted(.heading(file: entry.path, offset: entry.offset)), entry.path))
        default:
            return .success((template, nil))
        }
    }

    private func finish() {
        guard let template else { return }
        let opened = context.now
        let now = Date()
        let placed = resolved(template).flatMap { resolved in
            session.capture(text, template: resolved.template, root: workspace.rootPaths.first, file: resolved.file, now: now)
        }
        switch placed {
        case .failure(let error):
            problem = error.message
            if template.options.immediateFinish { editing = true }
            return
        case .success(let entry):
            commands.show("Captured to \(target(template))")
            let options = template.options
            if options.clockIn {
                // Clocked from when capture began; the clock it interrupted resumes after.
                let previous = clock.entry(session)
                commands.show(clock.clockIn(session, path: entry.path, at: entry.offset, now: opened))
                if !options.clockKeep {
                    commands.show(clock.clockOut(session, now: now))
                    if options.clockResume, let previous {
                        commands.show(clock.clockIn(session, path: previous.path, at: previous.offset, now: now))
                    }
                }
            }
            if options.jumpToCaptured { commands.jump(path: entry.path, offset: entry.offset) }
        }
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
