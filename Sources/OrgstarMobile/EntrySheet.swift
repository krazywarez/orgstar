#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgPresentation
import SwiftUI

/// An agenda entry's title, state, priority, dates, tags and notes, changed by the editor's
/// commands on a copy of its file and written back as one edit on Done.
struct EntrySheet: View {
    let item: AgendaItem
    let workspace: WorkspaceModel
    let session: DocumentSession
    /// Whether anything was written, and the entry to show in its file.
    let done: (_ saved: Bool, _ open: (path: String, offset: Int)?) -> Void
    @Environment(MobileModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: DocumentState?
    @State private var original = ""
    @State private var offset = 0
    @State private var title = ""
    @State private var notes = ""
    /// Changes on the copy that undo may take back, and those redo may bring back: the copy of
    /// an open file has the editor's history too.
    @State private var steps = 0
    @State private var undone = 0
    @State private var problem: String?
    @State private var prompt: PendingPrompt?
    @State private var planning: Planning?
    @State private var choosingTags = false
    @State private var confirmingDiscard = false

    private enum Planning: String, Identifiable {
        case scheduled = "Scheduled", deadline = "Deadline"
        var id: String { rawValue }
    }

    private struct PendingPrompt: Identifiable {
        let id = UUID()
        let prompt: Prompt
        let reply: (String?) -> Void
    }

    private var fields: EntryFields? {
        draft.flatMap { EntryFields.read($0.text, at: offset, settings: $0.tree.settings) }
    }

    private var hasChanges: Bool {
        guard let draft, let fields else { return false }
        return draft.text != original || title != fields.title || trimmed(notes) != fields.notes
    }

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        NavigationStack {
            Group {
                if let fields, let draft {
                    form(fields, settings: draft.tree.settings)
                } else if let problem {
                    ContentUnavailableView("Can't open the entry", systemImage: "exclamationmark.triangle", description: Text(problem))
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Cancel", systemImage: "xmark") {
                        if hasChanges { confirmingDiscard = true } else { done(false, nil) }
                    }
                    Button("Undo", systemImage: "arrow.uturn.backward", action: undo).disabled(steps == 0)
                    Button("Redo", systemImage: "arrow.uturn.forward", action: redo).disabled(undone == 0)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Open in File", systemImage: "doc.text") { save(open: true) }
                    }
                    .disabled(draft == nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { save() }.disabled(draft == nil)
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { done(false, nil) }
            }
        }
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(hasChanges)
        .task { load() }
        .sheet(item: $prompt) { pending in
            PromptSheet(prompt: pending.prompt) { answer in
                prompt = nil
                pending.reply(answer)
            }
        }
        .sheet(item: $planning) { which in
            let stamp = which == .scheduled ? fields?.scheduled : fields?.deadline
            DateTimeSheet(title: which.rawValue, initial: stamp.flatMap(Self.timestamp).map(Self.date) ?? Calendar.current.startOfDay(for: Date())) { answer in
                planning = nil
                if let answer { run(SetPlanning(deadline: which == .deadline), ["date": answer]) }
            }
        }
        .sheet(isPresented: $choosingTags) {
            TagsSheet(selected: fields?.tags ?? [], choices: (try? workspace.index.tags()) ?? []) { tags in
                choosingTags = false
                guard let tags, let old = fields?.tags else { return }
                for tag in old where !tags.contains(tag) { run(ToggleTag(tag: tag, on: false)) }
                for tag in tags where !old.contains(tag) { run(ToggleTag(tag: tag, on: true)) }
            }
        }
    }

    private func form(_ fields: EntryFields, settings: OrgSettings) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: $title, axis: .vertical)
                    .font(.title3.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        stateChip(fields, settings: settings)
                        priorityChip(fields, settings: settings)
                        dateChip(.scheduled, fields.scheduled)
                        dateChip(.deadline, fields.deadline)
                    }
                }
                Button {
                    choosingTags = true
                } label: {
                    chip(fields.tags.isEmpty ? String(localized: "Tags") : fields.tags.joined(separator: " "), systemImage: "tag", color: fields.tags.isEmpty ? .secondary : .accentColor)
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
            Divider()
            TextEditor(text: $notes)
                .font(.body)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 240)
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Add notes").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func stateChip(_ fields: EntryFields, settings: OrgSettings) -> some View {
        let keywords = settings.todoSequences.flatMap { $0.active.map(\.name) + $0.done.map(\.name) }
        let color = fields.todo.flatMap { todo in
            model.theme.todoColor(todo, isDone: settings.todoSequences.contains { $0.done.contains { $0.name == todo } }, dark: isDark)?.swiftUI
        } ?? .secondary
        return Menu {
            ForEach(keywords, id: \.self) { keyword in
                Button(keyword) { run(SetTodo(keyword: keyword)) }
            }
            Button("None") { run(SetTodo(keyword: nil)) }
        } label: {
            chip(fields.todo ?? String(localized: "No State"), color: color)
        }
    }

    @ViewBuilder
    private func priorityChip(_ fields: EntryFields, settings: OrgSettings) -> some View {
        let priorities = CaptureEntry.priorities(settings.priorities)
        if !priorities.isEmpty {
            let color = fields.priority.flatMap { model.theme.priorityColor($0, dark: isDark)?.swiftUI } ?? .secondary
            Menu {
                ForEach(priorities, id: \.self) { priority in
                    Button("Priority \(priority)") { run(SetPriority(), ["priority": priority]) }
                }
                Button("None") { run(SetPriority(), ["priority": " "]) }
            } label: {
                chip(fields.priority.map { "#" + $0 } ?? "#", color: color)
            }
            .accessibilityLabel(fields.priority.map { "Priority \($0)" } ?? "No priority")
        }
    }

    private func dateChip(_ which: Planning, _ value: String?) -> some View {
        let stamp = value.flatMap(Self.timestamp)
        return Menu {
            Button("Today") { set(which, days: 0, keeping: stamp) }
            Button("Tomorrow") { set(which, days: 1, keeping: stamp) }
            Button("In a Week") { set(which, days: 7, keeping: stamp) }
            Button("Pick Date…") { planning = which }
            if value != nil {
                Button("Remove", role: .destructive) { run(RemovePlanning(deadline: which == .deadline)) }
            }
        } label: {
            chip(stamp.map { which == .scheduled ? String(localized: "S: \(Self.text($0))") : String(localized: "D: \(Self.text($0))") }
                    ?? (which == .scheduled ? String(localized: "Schedule") : String(localized: "Deadline")),
                 systemImage: which == .scheduled ? "calendar" : "flag", color: stamp == nil ? .secondary : .accentColor)
        }
    }

    private func chip(_ text: String, systemImage: String? = nil, color: Color) -> some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: - Changes

    private func load() {
        guard draft == nil else { return }
        guard let path = item.path, let line = item.headingLine, let near = item.headingOffset,
              let at = session.locateHeading(path: path, line: line, near: near), let copy = session.copy(of: path),
              let fields = EntryFields.read(copy.text, at: at, settings: copy.tree.settings) else {
            problem = "The entry changed or its file can't be read."
            return
        }
        (draft, original, offset, title, notes) = (copy, copy.text, at, fields.title, fields.notes)
    }

    /// Runs `command` at the heading on the copy, asking what it asks.
    private func run(_ command: any OrgCommand, _ answers: [String: String] = [:]) {
        guard var copy = draft else { return }
        do {
            switch try copy.run(command, selection: [offset..<offset], answers: answers, options: session.options) {
            case .commit:
                problem = nil
                guard copy.text != draft?.text else { return }
                draft = copy
                steps += 1
                undone = 0
            case .prompt(let request):
                prompt = PendingPrompt(prompt: request) { answer in
                    if let answer { run(command, answers.merging([request.key: answer]) { $1 }) }
                }
            case .failed(let text):
                problem = text
            case .external(let request):
                problem = MobileEditor.unavailable(request, title: command.title)
            }
        } catch {
            problem = "\(error)"
        }
    }

    private func undo() {
        guard steps > 0, var copy = draft, copy.undo() != nil else { return }
        draft = copy
        steps -= 1
        undone += 1
    }

    private func redo() {
        guard undone > 0, var copy = draft, copy.redo() != nil else { return }
        draft = copy
        undone -= 1
        steps += 1
    }

    /// `days` from today, at the time `stamp` has.
    private func set(_ which: Planning, days: Int, keeping stamp: Timestamp?) {
        var day = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        if let hour = stamp?.start.hour {
            day = Calendar.current.date(bySettingHour: hour, minute: stamp?.start.minute ?? 0, second: 0, of: day) ?? day
        }
        run(SetPlanning(deadline: which == .deadline), ["date": QuestionField.stamp(day, withTime: stamp?.start.hour != nil)])
    }

    /// The title and notes onto the copy, and the copy written back to the file.
    private func save(open: Bool = false) {
        guard let path = item.path, let fields else { return }
        if title != fields.title { run(SetHeadingTitle(title: title)) }
        if trimmed(notes) != fields.notes { run(SetEntryNotes(notes: notes)) }
        guard let draft else { return }
        var saved = false
        if let command = ReplaceChangedText(from: original, to: draft.text) {
            if case .failed(let text) = session.perform(command, path: path, at: offset, expect: nil) {
                problem = text
                return
            }
            saved = true
        }
        done(saved, open ? (path, offset) : nil)
    }

    private func trimmed(_ text: String) -> String {
        var text = text
        while text.last?.isWhitespace == true { text.removeLast() }
        return text
    }

    private static func timestamp(_ value: String) -> Timestamp? { Timestamp.parse("<" + value + ">") }

    private static func date(_ stamp: Timestamp) -> Date {
        let p = stamp.start
        return Calendar.current.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: p.hour, minute: p.minute)) ?? Date()
    }

    /// `Sat 17 Oct`, with the time when it has one.
    private static func text(_ stamp: Timestamp) -> String {
        let day = date(stamp).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard let hour = stamp.start.hour else { return day }
        return day + String(format: " %02d:%02d", hour, stamp.start.minute ?? 0)
    }
}
#endif
