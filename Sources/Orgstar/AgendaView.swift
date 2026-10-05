import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

/// The agenda window: the day/week agenda, the TODO list, tag matches and saved views.
/// Return or a double click jumps to the entry in the main window. Keys as in Emacs's agenda:
/// f/b/. move the span, g refreshes, t cycles the TODO state, +/- change the priority, : or
/// C-c C-q sets tags, C-c C-s / C-c C-d schedule and set a deadline, S-→/S-← move the date.
struct AgendaView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    let scheduler: ReminderScheduler?
    @State private var agenda: AgendaModel
    @State private var views = AgendaViewLoader.builtIn
    @State private var viewName = AgendaViewLoader.builtIn[0].name
    @State private var matchText = ""
    @State private var selection: String?
    @State private var tick = 0
    @State private var message: String?
    @State private var prompt: PendingPrompt?
    @State private var promptText = ""
    @State private var prefix = false
    @AppStorage("agendaSpan") private var span = 10
    @AppStorage("agendaStartOffset") private var startOffset = -3
    @AppStorage("agendaSubfolders") private var includeSubfolders = false
    @Environment(\.openWindow) private var openWindow

    static let match = "Match…"
    static let todoMatch = "TODO Match…"

    init(workspace: WorkspaceModel, session: DocumentSession, commands: AppCommands, scheduler: ReminderScheduler?) {
        self.workspace = workspace
        self.session = session
        self.commands = commands
        self.scheduler = scheduler
        _agenda = State(initialValue: AgendaModel(workspace: workspace))
    }

    struct PendingPrompt: Identifiable {
        let id = UUID()
        let prompt: Prompt
        let command: any OrgCommand
        let atMarker: Bool
        let answers: [String: String]
        let itemID: String
    }

    private struct RefreshKey: Hashable {
        var mode: AgendaMode
        var start: Int?
        var span: Int
        var startOffset: Int
        var includeSubfolders: Bool
        var files: Int
        var changed: Int?
        var edits: Int
        var path: String?
        var tick: Int
    }

    private var refreshKey: RefreshKey {
        RefreshKey(
            mode: agenda.mode, start: agenda.start, span: span, startOffset: startOffset, includeSubfolders: includeSubfolders,
            files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion,
            path: session.path, tick: tick
        )
    }

    private var isAgenda: Bool {
        if case .agenda = agenda.mode { return true }
        return false
    }

    private var isMatch: Bool { viewName == Self.match || viewName == Self.todoMatch }

    @Environment(\.orgTheme) private var theme

    var body: some View {
        List(selection: $selection) {
            if isAgenda {
                ForEach(agenda.days, id: \.day) { day in
                    Section {
                        rows(day.items, prefix: "\(day.day)", day: day.day)
                    } header: {
                        Text(day.header)
                            .font(.headline)
                            .foregroundStyle(day.isToday ? theme.color("agenda-today") ?? .accentColor : theme.color("agenda-date") ?? .primary)
                    }
                }
            } else {
                Section {
                    rows(agenda.list, prefix: "list")
                } header: {
                    Text(listTitle).font(.headline)
                }
            }
        }
        .themedListBackground(theme.color("agenda-background"))
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first { jump(id) }
        }
        .onKeyPress(phases: .down) { press in handle(press) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = message ?? reminderStatus {
                Text(message)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    ForEach(views) { view in Button(view.name) { viewName = view.name } }
                    Divider()
                    Button(Self.match) { viewName = Self.match }
                    Button(Self.todoMatch) { viewName = Self.todoMatch }
                } label: {
                    Label(viewName, systemImage: "calendar").labelStyle(.titleAndIcon)
                }
                .help("What the agenda shows")
                if isMatch {
                    TextField("+work-boss|LEVEL>2/!TODO", text: $matchText)
                        .frame(minWidth: 220)
                        .onSubmit { applyView() }
                }
            }
            ToolbarItemGroup {
                if agenda.isComputing { ProgressView().controlSize(.small) }
                if isAgenda {
                    Button("Earlier", systemImage: "chevron.left") { agenda.shift(forward: false) }
                        .help("Previous days (b)")
                    Button("Today") { agenda.showToday() }
                        .help("Back to today (.)")
                    Button("Later", systemImage: "chevron.right") { agenda.shift(forward: true) }
                        .help("Next days (f)")
                }
            }
        }
        .overlay {
            if agenda.files.isEmpty {
                ContentUnavailableView("No agenda files", systemImage: "calendar", description: Text("The agenda reads the org files at the top of each folder you add."))
            }
        }
        .alert(prompt?.prompt.message ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("", text: $promptText)
            Button("OK") { answerPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        } message: {
            if let choices = prompt?.prompt.choices, !choices.isEmpty {
                Text(choices.prefix(12).joined(separator: "  "))
            }
        }
        .navigationTitle(viewName.replacingOccurrences(of: "…", with: ""))
        .onChange(of: viewName) { applyView() }
        .task(id: refreshKey) {
            agenda.span = span
            agenda.startOffset = startOffset
            agenda.includeSubfolders = includeSubfolders
            let open = session.path.flatMap { path in session.document.map { (path, $0.text) } }
            await agenda.refresh(open: open)
        }
        .task {
            loadViews()
            // The time grid's "now" line and the day itself move on.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                tick += 1
            }
        }
    }

    @ViewBuilder
    private func rows(_ items: [AgendaItem], prefix: String, day: Int? = nil) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            AgendaRow(item: item, day: day)
                .tag("\(prefix):\(index)")
                .selectionDisabled(item.path == nil)
        }
    }

    @AppStorage("reminders") private var remindersEnabled = true

    /// How far ahead notifications are set, as the design asks the agenda to show.
    private var reminderStatus: String? {
        guard let scheduler, remindersEnabled else { return nil }
        if !scheduler.isAuthorized { return "Notifications are off for Orgstar in System Settings." }
        guard let through = scheduler.scheduledThrough else { return nil }
        return "Reminders are set through " + through.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) + "."
    }

    private var listTitle: String {
        switch agenda.mode {
        case .todo(let keywords): "TODO items: \(keywords ?? "all")"
        case .match(let match, let todoOnly): (todoOnly ? "TODO entries" : "Entries") + " matching \(match)"
        case .agenda: ""
        }
    }

    private func loadViews() {
        let loaded = AgendaViewLoader.load()
        views = loaded.views
        message = loaded.problems.first
    }

    private func applyView() {
        selection = nil
        agenda.start = nil
        switch viewName {
        case Self.match, Self.todoMatch:
            let match = matchText.trimmingCharacters(in: .whitespaces)
            guard !match.isEmpty else { return }
            agenda.mode = .match(match, todoOnly: viewName == Self.todoMatch)
        default:
            if let view = views.first(where: { $0.name == viewName }) { agenda.mode = view.mode }
        }
    }

    // MARK: - Items

    private func item(_ id: String) -> AgendaItem? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, let index = Int(parts[1]) else { return nil }
        let items = parts[0] == "list" ? agenda.list : agenda.days.first { "\($0.day)" == parts[0] }?.items ?? []
        return index < items.count ? items[index] : nil
    }

    private func jump(_ id: String) {
        guard let item = item(id), let path = item.path, let offset = item.markerOffset ?? item.headingOffset else { return }
        commands.jump(path: path, offset: offset)
        openWindow(id: "main")
    }

    // MARK: - Commands

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let control = press.modifiers.contains(.control)
        if prefix {
            prefix = false
            switch (control, press.characters) {
            case (true, "\u{13}"), (true, "s"): run(SetPlanning(deadline: false))
            case (true, "\u{04}"), (true, "d"): run(SetPlanning(deadline: true))
            case (true, "\u{11}"), (true, "q"): run(SetTags())
            case (true, "\u{14}"), (true, "t"): run(TodoCycle())
            default: message = "C-c \(press.characters) is undefined"
            }
            return .handled
        }
        if control, press.characters == "c" || press.characters == "\u{03}" {
            prefix = true
            message = "C-c-"
            return .handled
        }
        if press.key == .return, let selection {
            jump(selection)
            return .handled
        }
        if press.modifiers == .shift, press.key == .rightArrow || press.key == .leftArrow {
            run(ShiftTimestampDay(later: press.key == .rightArrow), atMarker: true)
            return .handled
        }
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch press.characters {
        case "f" where isAgenda: agenda.shift(forward: true)
        case "b" where isAgenda: agenda.shift(forward: false)
        case "." where isAgenda: agenda.showToday()
        case "g", "r":
            loadViews()
            tick += 1
        case "t": run(TodoCycle())
        case "+": run(PriorityUp())
        case "-": run(PriorityDown())
        case ":": run(SetTags())
        default: return .ignored
        }
        return .handled
    }

    /// Runs `command` on the selected entry, at its heading or, with `atMarker`, at the
    /// timestamp the entry is listed for.
    private func run(_ command: any OrgCommand, atMarker: Bool = false, answers: [String: String] = [:], itemID: String? = nil) {
        guard let id = itemID ?? selection, let item = item(id), let path = item.path, let start = item.headingOffset else {
            message = "No entry selected"
            return
        }
        if atMarker, ![.deadline, .upcomingDeadline, .scheduled, .pastScheduled, .timestamp].contains(item.kind) {
            message = "Only dated entries can move"
            return
        }
        let offset = atMarker ? (item.markerOffset ?? start) : start
        let step = session.perform(command, path: path, at: offset, expect: item.headingLine.map { (start, $0) }, answers: answers)
        switch step {
        case .prompt(let request):
            promptText = request.initial
            prompt = PendingPrompt(prompt: request, command: command, atMarker: atMarker, answers: answers, itemID: id)
        case .failed(let text):
            message = text
            tick += 1
        case .external:
            message = "Not available from the agenda"
        case .commit:
            message = nil
            tick += 1
        }
    }

    private func answerPrompt() {
        guard let pending = prompt else { return }
        prompt = nil
        var answers = pending.answers
        answers[pending.prompt.key] = promptText
        run(pending.command, atMarker: pending.atMarker, answers: answers, itemID: pending.itemID)
    }
}

struct AgendaRow: View {
    let item: AgendaItem
    /// The agenda day the row is on, for habit graphs.
    var day: Int?
    @Environment(\.orgTheme) private var theme

    var body: some View {
        switch item.kind {
        case .timeGrid:
            HStack(spacing: 8) {
                Text(Self.trim(item.time))
                    .monospacedDigit()
                    .frame(width: 140, alignment: .trailing)
                VStack { Divider() }
            }
            .font(.caption)
            .foregroundStyle(theme.color("agenda-time").map(AnyShapeStyle.init) ?? AnyShapeStyle(.tertiary))
        case .currentTime:
            HStack(spacing: 8) {
                Text("now " + Self.trim(item.time))
                    .monospacedDigit()
                    .frame(width: 140, alignment: .trailing)
                Rectangle().fill(theme.color("agenda-today") ?? .accentColor).frame(height: 1)
            }
            .font(.caption)
            .foregroundStyle(theme.color("agenda-today") ?? .accentColor)
        default:
            HStack(spacing: 8) {
                Text(item.category)
                    .lineLimit(1)
                    .foregroundStyle(theme.color("agenda-category") ?? .secondary)
                    .frame(width: 80, alignment: .leading)
                if item.kind != .todo, item.kind != .tagsMatch {
                    Text(Self.trim(item.time))
                        .monospacedDigit()
                        .foregroundStyle(theme.color("agenda-time") ?? .primary)
                        .frame(width: 80, alignment: .leading)
                }
                if !item.extra.isEmpty {
                    Text(item.extra.trimmingCharacters(in: .whitespaces))
                        .monospacedDigit()
                        .foregroundStyle(leaderColor)
                }
                title
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let habit = item.habit, let day {
                    HabitGraph(cells: habit.graph(today: day), theme: theme)
                }
                if !item.tags.isEmpty {
                    Text(":" + item.tags.joined(separator: ":") + ":")
                        .font(.caption)
                        .foregroundStyle(theme.color("tags") ?? .secondary)
                }
            }
        }
    }

    static func trim(_ time: String) -> String {
        time.trimmingCharacters(in: CharacterSet(charactersIn: " ┄."))
    }

    private var leaderColor: Color {
        switch item.kind {
        case .deadline: theme.color("agenda-deadline") ?? .red
        case .upcomingDeadline: theme.color("agenda-upcoming") ?? .orange
        case .pastScheduled: theme.color("agenda-scheduled-past") ?? .brown
        default: theme.color("agenda-scheduled") ?? .secondary
        }
    }

    /// The TODO keyword colored as in the editor.
    private var title: Text {
        let text = item.text.trimmingCharacters(in: .whitespaces)
        guard let todo = item.todo, text.hasPrefix(todo + " ") else { return Text(text) }
        let rest = String(text.dropFirst(todo.count))
        let rest_ = Text(rest).foregroundColor(item.isDone ? theme.color("comment") ?? .secondary : theme.color("foreground") ?? .primary)
        return Text(todo).foregroundColor(theme.keywordColor(todo, done: item.isDone)).bold() + rest_
    }
}

/// org-habit's consistency graph: a cell per day, `*` where the habit was done, `!` today.
struct HabitGraph: View {
    let cells: [Habit.Cell]
    var theme: ThemeSpec = .default

    var body: some View {
        HStack(spacing: 1) {
            ForEach(cells, id: \.day) { cell in
                Text(String(cell.glyph))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .frame(width: 8, height: 14)
                    .background(color(cell.face))
                    .help(Self.label(cell))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Done \(cells.filter { $0.glyph == "*" }.count) of the last \(Habit.precedingDays) days")
    }

    /// Due-state colors, lighter for days to come, as org-habit's faces.
    func color(_ face: Habit.Face) -> Color {
        func themed(_ key: String, _ fallback: Color) -> Color { theme.color(key) ?? fallback }
        switch face {
        case .clear: return themed("habit-clear", .blue).opacity(0.7)
        case .clearFuture: return themed("habit-clear", .blue).opacity(0.35)
        case .ready: return themed("habit-ready", .green).opacity(0.75)
        case .readyFuture: return themed("habit-ready", .green).opacity(0.35)
        case .alert: return themed("habit-alert", .yellow).opacity(0.85)
        case .alertFuture: return themed("habit-alert", .yellow).opacity(0.4)
        case .overdue: return themed("habit-overdue", .red).opacity(0.75)
        case .overdueFuture: return themed("habit-overdue", .red).opacity(0.35)
        }
    }

    static func label(_ cell: Habit.Cell) -> String {
        let date = Days.date(cell.day)
        return String(format: "%04d-%02d-%02d", date.year, date.month, date.day) + (cell.glyph == "*" ? " DONE" : "")
    }
}
