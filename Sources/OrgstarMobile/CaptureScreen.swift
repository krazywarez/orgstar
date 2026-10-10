#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
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
                            .frame(minHeight: 120)
                            .focused($focused)
                    } footer: {
                        if let problem { Text(problem).foregroundStyle(.red) }
                    }
                    if let entry = CaptureEntry(text: text, defaults: session.defaults) {
                        EntryFields(entry: entry, tagChoices: Array(Set(context.allTags + context.fileTags)).sorted(), change: change)
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
            let (filledText, cursor) = request.day.map { Capture.scheduling(filled.text, cursor: filled.cursor, on: $0) } ?? (filled.text, filled.cursor)
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

    /// The entry's text after `command`, as the editor runs it. Changing a date here isn't a
    /// reschedule, so it isn't logged as one.
    private func change(_ command: any OrgCommand, _ answers: [String: String]) {
        var options = session.options
        options.logReschedule = nil
        options.logRedeadline = nil
        if let changed = CaptureEntry.applying(command, answers: answers, to: text, defaults: session.defaults, options: options, now: context.now) {
            text = changed
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

    private func file() {
        guard let template else { return }
        let now = Date()
        let placed = template.resolved(workspace: workspace, session: session, clock: clock).flatMap { resolved in
            session.capture(text, template: resolved.template, root: workspace.rootPaths.first, file: resolved.file, now: request.day.map(Self.date) ?? now)
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
/// The captured entry's keyword, priority, dates and tags, set without editing its text.
private struct EntryFields: View {
    let entry: CaptureEntry
    let tagChoices: [String]
    let change: (any OrgCommand, [String: String]) -> Void
    @State private var planning: Planning?
    @State private var choosingTags = false

    private enum Planning: String, Identifiable {
        case scheduled = "Scheduled", deadline = "Deadline"
        var id: Self { self }
    }

    var body: some View {
        Section {
            Picker("State", selection: Binding { entry.todo ?? "" } set: { change(SetTodo(keyword: $0.isEmpty ? nil : $0), [:]) }) {
                Text("None").tag("")
                ForEach(entry.keywords, id: \.self) { Text($0).tag($0) }
            }
            if !entry.priorities.isEmpty {
                Picker("Priority", selection: Binding { entry.priority ?? "" } set: { change(SetPriority(), ["priority": $0.isEmpty ? " " : $0]) }) {
                    Text("None").tag("")
                    ForEach(entry.priorities, id: \.self) { Text($0).tag($0) }
                }
            }
            date(.scheduled, entry.scheduled)
            date(.deadline, entry.deadline)
            Button {
                choosingTags = true
            } label: {
                LabeledContent("Tags", value: entry.tags.isEmpty ? "None" : entry.tags.joined(separator: " "))
            }
            .tint(.primary)
        }
        .sheet(item: $planning) { which in
            DateTimeSheet(title: which.rawValue, initial: initial(which == .scheduled ? entry.scheduled : entry.deadline)) { answer in
                planning = nil
                if let answer { change(SetPlanning(deadline: which == .deadline), ["date": answer]) }
            }
        }
        .sheet(isPresented: $choosingTags) {
            TagsSheet(selected: entry.tags, choices: tagChoices) { tags in
                choosingTags = false
                if let tags { change(SetTags(), ["tags": tags.joined(separator: ":")]) }
            }
        }
    }

    private func date(_ which: Planning, _ stamp: Timestamp?) -> some View {
        Menu {
            Button("Today") { set(which, 0) }
            Button("Tomorrow") { set(which, 1) }
            Button("In a Week") { set(which, 7) }
            Button("Pick Date…") { planning = which }
            if stamp != nil {
                Button("Remove", role: .destructive) { change(RemovePlanning(deadline: which == .deadline), [:]) }
            }
        } label: {
            LabeledContent(which.rawValue, value: stamp.map(Self.text) ?? "None")
        }
        .tint(.primary)
    }

    private func set(_ which: Planning, _ days: Int) {
        let day = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        change(SetPlanning(deadline: which == .deadline), ["date": QuestionField.stamp(day, withTime: false)])
    }

    private func initial(_ stamp: Timestamp?) -> Date {
        guard let stamp else { return Date() }
        let point = stamp.start
        return Calendar.current.date(from: DateComponents(year: point.year, month: point.month, day: point.day, hour: point.hour, minute: point.minute)) ?? Date()
    }

    /// `Sat 12 Oct`, with the time when it has one.
    private static func text(_ stamp: Timestamp) -> String {
        let point = stamp.start
        let date = Calendar.current.date(from: DateComponents(year: point.year, month: point.month, day: point.day)) ?? Date()
        let day = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard let hour = point.hour else { return day }
        return day + String(format: " %02d:%02d", hour, point.minute ?? 0)
    }
}

/// A date and, when switched on, a time; the answer as a date prompt takes it.
private struct DateTimeSheet: View {
    let title: String
    let initial: Date
    let done: (String?) -> Void
    @State private var date = Date()
    @State private var withTime = false

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(title, selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                Toggle("Time", isOn: $withTime)
                if withTime { DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("Set") { done(QuestionField.stamp(date, withTime: withTime)) } }
            }
        }
        .presentationDetents([.large])
        .onAppear { date = initial }
    }
}

/// Tags to toggle, from the file and the workspace, and new ones typed in.
private struct TagsSheet: View {
    let choices: [String]
    let done: ([String]?) -> Void
    @State private var selected: [String]
    @State private var typed = ""

    init(selected: [String], choices: [String], done: @escaping ([String]?) -> Void) {
        _selected = State(initialValue: selected)
        self.choices = choices
        self.done = done
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("New tag", text: $typed)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(add)
                }
                Section {
                    ForEach(Array(Set(choices + selected)).sorted(), id: \.self) { tag in
                        Button {
                            if selected.contains(tag) { selected.removeAll { $0 == tag } } else { selected.append(tag) }
                        } label: {
                            HStack {
                                Text(tag).foregroundStyle(.primary)
                                Spacer()
                                if selected.contains(tag) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        add()
                        done(selected)
                    }
                }
            }
        }
    }

    /// The typed tags, `:` or spaces between several, added and checked.
    private func add() {
        for tag in typed.split(whereSeparator: { $0 == ":" || $0 == " " }).map(String.init) where !selected.contains(tag) { selected.append(tag) }
        typed = ""
    }
}
#endif
