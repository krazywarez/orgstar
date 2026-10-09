#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI

/// Capture with a template: its questions (`%^{…}`, `%^g`, `%^t`…), then its text to edit,
/// filed where the template says, as `org-capture` does.
struct CaptureScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let request: CaptureRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(ClockModel.self) private var clock
    @Environment(MobileModel.self) private var model
    @State private var templates: [CaptureTemplate] = []
    @State private var key: String?
    @State private var context = CaptureContext()
    @State private var questions: [Capture.Question] = []
    @State private var answers: [String] = []
    @State private var editing = false
    @State private var text = ""
    @State private var selection: TextSelection?
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var template: CaptureTemplate? { templates.first { $0.key == key } }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Template", selection: $key) {
                    ForEach(templates) { Text($0.name).tag(Optional($0.key)) }
                }
                if editing {
                    Section {
                        TextEditor(text: $text, selection: $selection)
                            .font(.body.monospaced())
                            .frame(minHeight: 200)
                            .focused($focused)
                    } footer: {
                        if let problem { Text(problem).foregroundStyle(.red) }
                    }
                } else {
                    ForEach(questions.indices, id: \.self) { index in
                        QuestionField(question: questions[index], answer: $answers[index])
                    }
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if editing {
                        Button("File", action: file).disabled(template == nil)
                    } else {
                        Button("Continue", action: fill)
                    }
                }
            }
        }
        .onAppear {
            let loaded = CaptureTemplates.load()
            templates = loaded.templates
            problem = loaded.problems.first
            key = request.template.flatMap { wanted in templates.first { $0.key == wanted }?.key } ?? templates.first?.key
            if let wanted = request.template, !templates.contains(where: { $0.key == wanted }) { problem = "No capture template \"\(wanted)\"" }
        }
        .onChange(of: key, initial: true) { choose() }
    }

    /// The template's questions, asked before its text; none, and the text shows at once.
    private func choose() {
        guard let template else { return }
        context = CaptureContext(
            initial: request.properties["initial"] ?? "", annotation: request.properties["annotation"] ?? "",
            allTags: (try? workspace.index.tags()) ?? []
        )
        context.linkProperties = request.properties
        // `%^g` offers the target file's tags.
        let path = DocumentSession.resolve(template.target.file, root: workspace.rootPaths.first)
        if !template.target.file.isEmpty,
           let source = session.openTexts[path] ?? (try? String(contentsOfFile: path, encoding: .utf8)) {
            var tags: [String] = []
            for heading in DocumentModel(tree: OrgParser.parse(source)).headings { for tag in heading.localTags where !tags.contains(tag) { tags.append(tag) } }
            context.fileTags = tags
        }
        questions = Capture.questions(template.template, context: context)
        answers = questions.map { _ in "" }
        editing = false
        if questions.isEmpty { fill() }
    }

    /// The template expanded with the answers; the caret where `%?` was.
    private func fill() {
        guard let template else { return }
        context.now = Date()
        switch Capture.fill(template.template, context: context, answers: answers) {
        case .success(let filled):
            text = filled.text
            selection = TextSelection(insertionPoint: String.Index(utf16Offset: filled.cursor, in: filled.text))
            problem = nil
            editing = true
            focused = true
            if template.options.immediateFinish { file() }
        case .failure(.message(let message)):
            problem = message
        }
    }

    private func file() {
        guard let template else { return }
        let now = Date()
        let placed = template.resolved(workspace: workspace, session: session, clock: clock).flatMap { resolved in
            session.capture(text, template: resolved.template, root: workspace.rootPaths.first, file: resolved.file, now: now)
        }
        switch placed {
        case .failure(let error):
            problem = error.message
            editing = true
        case .success(let entry):
            // Clocked from when capture began.
            let paths = workspace.files.filter { $0.kind == .org }.map(\.path)
            Task { [clock, session, opened = context.now] in
                _ = await clock.captured(entry, options: template.options, session: session, paths: paths, ask: model.clockPrompts.ask, opened: opened, now: now)
            }
            if template.options.jumpToCaptured { model.openRequest = .offset(entry.path, entry.offset) }
            dismiss()
        }
    }
}

/// One of a template's questions: text with its choices, tags, or a date.
struct QuestionField: View {
    let question: Capture.Question
    @Binding var answer: String
    @State private var date = Date()

    var body: some View {
        Section {
            TextField(placeholder, text: $answer)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if case .date(let withTime, _) = question.kind {
                DatePicker("Date", selection: $date, displayedComponents: withTime ? [.date, .hourAndMinute] : [.date])
                    .onChange(of: date) { answer = Self.stamp(date, withTime: withTime) }
            }
            if !question.choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(question.choices.prefix(30), id: \.self) { choice in
                            Button(choice) { pick(choice) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        } header: {
            Text(question.prompt)
        }
    }

    /// What an empty answer means.
    private var placeholder: String {
        switch question.kind {
        case .text, .property, .clipboard: question.defaultValue
        case .tags: "tag:tag"
        case .date(let withTime, _): withTime ? "now; or +2d, fri 14:00" : "today; or +2d, fri"
        }
    }

    /// Tags add to what's typed; other choices replace it.
    private func pick(_ choice: String) {
        guard question.kind == .tags else { return answer = choice }
        let tags = answer.split(separator: ":").map(String.init)
        if !tags.contains(choice) { answer = (tags + [choice]).joined(separator: ":") }
    }

    static func stamp(_ date: Date, withTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = withTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
#endif
