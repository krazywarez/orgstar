import AppKit
import Carbon.HIToolbox
import OrgApp
import OrgCore
import OrgDocument
import SwiftUI

/// The capture window: pick a template by its key, answer its prompts, edit the entry, and
/// ⌘Return files it where the template says, as `org-capture` does. Refile… files it and then
/// asks where to move it (`org-capture-refile`).
struct CaptureView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    let clock: ClockModel
    @State private var templates = CaptureTemplates.defaults
    @State private var groups: [CaptureGroup] = []
    /// The day `:time-prompt` asked for.
    @State private var treeDate: Date?
    @State private var problem: String?
    @State private var template: CaptureTemplate?
    @State private var questions: [Capture.Question] = []
    @State private var answers: [String] = []
    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var context = CaptureContext()
    @State private var editing = false
    /// The template keys typed so far, for multi-key templates such as "wb".
    @State private var keys = ""
    /// The agenda day the entry is captured for, as `Days` numbers it.
    @State private var day: Int?
    @FocusState private var focused: Bool
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

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
                    if template.kind == .entry {
                        Button("Refile…") { finish(refile: true) }
                    }
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
                Text((keys.isEmpty ? "Capture" : "Capture: \(keys)") + (day == nil ? "" : ", scheduled " + captureDate(Date()).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))))
                    .font(.headline)
                ForEach(CaptureTemplates.menu(templates, groups: groups, typed: keys)) { item in
                    Button {
                        switch item {
                        case .group(let group): keys = group.key
                        case .template(let template): choose(template)
                        }
                    } label: {
                        HStack {
                            Text("[\(item.key)]").monospaced().foregroundStyle(.secondary)
                            switch item {
                            case .group(let group):
                                Text(group.name + "…")
                            case .template(let template):
                                Text(template.name)
                                Spacer()
                                Text(Self.target(template)).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .frame(width: 520)
        .onKeyPress(phases: .down) { press in
            guard template == nil else { return .ignored }
            if press.key == .delete, !keys.isEmpty {
                keys.removeLast()
                return .handled
            }
            // Keys narrow the list until they name a template, as `org-capture` selects one.
            let typed = keys + press.characters
            if let match = templates.first(where: { $0.key == typed }) {
                choose(match)
            } else if !press.characters.isEmpty, templates.contains(where: { $0.key.hasPrefix(typed) }) {
                keys = typed
            } else {
                return .ignored
            }
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
        case .regexp(_, let regexp): return "\(file) / \(regexp)"
        case .id(let id): return "ID \(id)"
        case .clock: return "clocked entry"
        }
    }

    private func reset() {
        let loaded = CaptureTemplates.load()
        templates = loaded.templates
        groups = loaded.groups
        problem = loaded.problems.first
        template = nil
        treeDate = nil
        editing = false
        keys = ""
        day = nil
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
        context.readsTemplateFiles()
    }

    /// An org-protocol capture: its link properties fill `%a`, `%i` and `%:…`, and its
    /// template, when it names one, is chosen.
    private func takeRequest() {
        guard let request = commands.captureRequest else { return }
        commands.captureRequest = nil
        day = request.day
        context.initial = request.properties["initial"] ?? ""
        context.annotation = request.properties["annotation"] ?? ""
        context.linkProperties = request.properties
        if let key = request.template {
            if let match = templates.first(where: { $0.key == key }) { choose(match) } else { problem = "No capture template \"\(key)\"" }
        }
    }

    private func choose(_ chosen: CaptureTemplate) {
        template = chosen
        keys = ""
        // `%^g` offers the target file's tags.
        let path = DocumentSession.resolve(chosen.target.file, root: workspace.rootPaths.first)
        if !chosen.target.file.isEmpty, let text = session.openDocuments.first(where: { $0.path == path })?.document.text ?? (try? String(contentsOfFile: path, encoding: .utf8)) {
            var tags: [String] = []
            for heading in DocumentModel(tree: OrgParser.parse(text)).headings { for tag in heading.localTags where !tags.contains(tag) { tags.append(tag) } }
            context.fileTags = tags
        }
        questions = (asksTreeDate(chosen) ? [Self.treeQuestion] : []) + Capture.questions(chosen.template, context: context)
        answers = questions.map { _ in "" }
        if questions.isEmpty { expand() }
    }

    /// `:time-prompt` asks first, unless the agenda day is the date.
    private func asksTreeDate(_ template: CaptureTemplate) -> Bool { template.asksTreeDate && day == nil }

    static let treeQuestion = Capture.Question(prompt: "Date for tree entry", defaultValue: "", choices: [], kind: .date(withTime: false, inactive: false))

    private func expand() {
        guard let template else { return }
        var answers = answers
        if asksTreeDate(template) {
            treeDate = Capture.treeDate(answers.removeFirst(), now: Date())
        }
        context.now = captureDate(Date())
        switch Capture.fill(template.template, context: context, answers: answers) {
        case .failure(.message(let message)):
            problem = message
            self.template = nil
        case .success(var filled):
            if let day { filled = Capture.scheduling(filled.text, cursor: filled.cursor, on: day) }
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

    /// `now` on the agenda day captured for, as `org-overriding-default-time` sets `%t`, `%U`
    /// and the date tree's day.
    private func captureDate(_ now: Date) -> Date {
        if let treeDate { return treeDate }
        guard let day else { return now }
        let d = Days.date(day)
        let time = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        return Calendar.current.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: time.hour, minute: time.minute, second: time.second)) ?? now
    }

    private func finish(refile: Bool = false) {
        guard let template else { return }
        let opened = context.now
        let now = Date()
        let placed = template.resolved(workspace: workspace, session: session, clock: clock).flatMap { resolved in
            session.capture(text, template: resolved.template, root: workspace.rootPaths.first, file: resolved.file, now: captureDate(now))
        }
        switch placed {
        case .failure(let error):
            problem = error.message
            if template.options.immediateFinish { editing = true }
            return
        case .success(let entry):
            commands.show("Captured to \(Self.target(template))")
            let options = template.options
            let paths = workspace.files.filter { $0.kind == .org }.map(\.path)
            Task { [commands, clock, session, workspace] in
                let outcome = await clock.captured(entry, options: options, session: session, paths: paths, ask: commands.askClock, opened: opened, now: now)
                for message in outcome.messages { commands.show(message) }
                if refile {
                    Self.refile(entry, session: session, workspace: workspace, commands: commands)
                } else if let jump = outcome.jump {
                    commands.jump(path: jump.path, offset: jump.offset)
                } else if options.jumpToCaptured {
                    commands.jump(path: entry.path, offset: entry.offset)
                }
            }
        }
        if refile { openWindow(id: "main") }
        close()
    }

    /// `org-capture-refile`: the filed entry, moved where the answer says.
    private static func refile(_ entry: (path: String, offset: Int), session: DocumentSession, workspace: WorkspaceModel, commands: AppCommands) {
        let document = session.openDocuments.first { $0.path == entry.path }?.document
            ?? FileManager.default.contents(atPath: entry.path).map { DocumentState(bytes: [UInt8]($0)) }
        let targets = workspace.refileTargets(openPath: entry.path, document: document)
        commands.ask(Prompt(key: "refile", message: "Refile to:", choices: targets.map(\.label))) { answer in
            guard let answer, let target = targets.first(where: { $0.label == answer }) else { return }
            if let message = session.refile(to: target, from: entry) { commands.show(message) }
        }
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
