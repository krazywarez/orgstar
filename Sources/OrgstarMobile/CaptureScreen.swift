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
                        QuestionField(question: questions[index], answer: $answers[index], defaultDate: request.day.map(Self.date))
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
        context.now = request.day.map(Self.date) ?? Date()
        switch Capture.fill(template.template, context: context, answers: answers) {
        case .success(let filled):
            let (filledText, cursor) = request.day.map { Self.scheduling(filled.text, cursor: filled.cursor, on: $0) } ?? (filled.text, filled.cursor)
            text = filledText
            selection = TextSelection(insertionPoint: String.Index(utf16Offset: cursor, in: filledText))
            problem = nil
            editing = true
            focused = true
            if template.options.immediateFinish { file() }
        case .failure(.message(let message)):
            problem = message
        }
    }

    /// Now's time of day on `day` (a `Days` number): the default time of an agenda day's
    /// capture, as `org-agenda-capture` sets `org-overriding-default-time`.
    static func date(_ day: Int) -> Date {
        let calendar = Calendar.current
        let d = Days.date(day)
        var parts = calendar.dateComponents([.hour, .minute, .second], from: Date())
        (parts.year, parts.month, parts.day) = (d.year, d.month, d.day)
        return calendar.date(from: parts) ?? Date()
    }

    /// An entry captured from an agenda day is scheduled on it: a SCHEDULED line goes under
    /// the heading unless the template already gave the entry an active timestamp. The caret
    /// keeps its place in the text.
    static func scheduling(_ text: String, cursor: Int, on day: Int) -> (String, Int) {
        guard text.hasPrefix("*"), text.firstMatch(of: /<[0-9]{4}-[0-9]{2}-[0-9]{2}/) == nil else { return (text, cursor) }
        let d = Days.date(day)
        let weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][Days.weekday(day)]
        let line = String(format: "SCHEDULED: <%04d-%02d-%02d ", d.year, d.month, d.day) + weekday + ">"
        let utf16 = Array(text.utf16)
        let end = utf16.firstIndex(of: 10) ?? utf16.count
        let inserted = "\n" + line
        let result = String(decoding: utf16[..<end], as: UTF16.self) + inserted + String(decoding: utf16[end...], as: UTF16.self)
        return (result, cursor > end ? cursor + inserted.utf16.count : cursor)
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
    /// What an empty date answer means: now, or the agenda day capture started from.
    let defaultDate: Date?
    @State private var date: Date

    init(question: Capture.Question, answer: Binding<String>, defaultDate: Date? = nil) {
        self.question = question
        _answer = answer
        self.defaultDate = defaultDate
        _date = State(initialValue: defaultDate ?? Date())
    }

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
        case .date(let withTime, _):
            defaultDate.map { Self.stamp($0, withTime: withTime) + "; or +2d, fri" }
                ?? (withTime ? "now; or +2d, fri 14:00" : "today; or +2d, fri")
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
