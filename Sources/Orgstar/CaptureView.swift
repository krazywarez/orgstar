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
                Text("\(template.name) → \(Self.target(template))").font(.headline)
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
                        let question = questions[index]
                        TextField(question.prompt, text: $answers[index], prompt: Text(placeholder(question)))
                        if !question.choices.isEmpty {
                            Text(question.choices.prefix(12).joined(separator: "  ")).font(.caption).foregroundStyle(.secondary)
                        }
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
                            Text(Self.target(template)).foregroundStyle(.secondary).font(.caption)
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
        .onAppear {
            reset()
            takeRequest()
        }
        .onChange(of: commands.captureRequest?.serial) {
            guard commands.captureRequest != nil else { return }
            reset()
            takeRequest()
        }
    }

    /// What an empty answer means.
    private func placeholder(_ question: Capture.Question) -> String {
        switch question.kind {
        case .text, .property, .clipboard: question.defaultValue
        case .tags: "tag:tag"
        case .date(let withTime, _): withTime ? "now; or +2d, fri 14:00" : "today; or +2d, fri"
        }
    }

    static func target(_ template: CaptureTemplate) -> String {
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
        let clocked = clock.running
        let clockFile = clocked.map { Links.abbreviate($0.path, home: NSHomeDirectory()) }
        context = CaptureContext(
            initial: commands.editor?.selectedText ?? "",
            annotation: session.captureAnnotation(),
            clipboard: NSPasteboard.general.string(forType: .string) ?? "",
            file: session.path ?? "",
            userName: NSFullUserName(),
            clockHeading: clocked?.heading ?? "",
            clockLink: clocked.map { "[[file:\(clockFile!)::*\($0.heading)][\($0.heading)]]" } ?? "",
            allTags: (try? workspace.index.tags()) ?? [],
            tagsColumn: UserDefaults.standard.object(forKey: "tagsColumn") as? Int ?? -77
        )
    }

    /// An org-protocol capture: its link properties fill `%a`, `%i` and `%:…`, and its
    /// template, when it names one, is chosen.
    private func takeRequest() {
        guard let request = commands.captureRequest else { return }
        commands.captureRequest = nil
        context.initial = request.properties["initial"] ?? ""
        context.annotation = request.properties["annotation"] ?? ""
        context.linkProperties = request.properties
        if let key = request.template {
            if let match = templates.first(where: { $0.key == key }) { choose(match) } else { problem = "No capture template \"\(key)\"" }
        }
    }

    private func choose(_ chosen: CaptureTemplate) {
        template = chosen
        // `%^g` offers the target file's tags.
        let path = DocumentSession.resolve(chosen.target.file, root: workspace.rootPaths.first)
        if !chosen.target.file.isEmpty, let text = session.openDocuments.first(where: { $0.path == path })?.document.text ?? (try? String(contentsOfFile: path, encoding: .utf8)) {
            var tags: [String] = []
            for heading in DocumentModel(tree: OrgParser.parse(text)).headings { for tag in heading.localTags where !tags.contains(tag) { tags.append(tag) } }
            context.fileTags = tags
        }
        questions = Capture.questions(chosen.template, context: context)
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
    static func resolved(
        _ template: CaptureTemplate, workspace: WorkspaceModel, session: DocumentSession, clock: ClockModel
    ) -> Result<(template: CaptureTemplate, file: String?), CaptureError> {
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
        let placed = Self.resolved(template, workspace: workspace, session: session, clock: clock).flatMap { resolved in
            session.capture(text, template: resolved.template, root: workspace.rootPaths.first, file: resolved.file, now: now)
        }
        switch placed {
        case .failure(let error):
            problem = error.message
            if template.options.immediateFinish { editing = true }
            return
        case .success(let entry):
            commands.show("Captured to \(Self.target(template))")
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
