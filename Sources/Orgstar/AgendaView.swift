import OrgApp
import OrgDocument
import OrgCore
import OrgPresentation
import SwiftUI

/// The agenda window: the day/week agenda, the TODO list, tag matches and saved views.
/// Return or a double click jumps to the entry in the main window. Keys as in Emacs's agenda:
/// f/b/. move the span, g refreshes, l shows the log (closed and clocked), / filters
/// (`+cat-tag<0:10-/regexp/`), \ by tag, < by the line's category, = by regexp, _ by effort,
/// | clears filters, I/O/X clock in, out and cancel, C-c C-w refiles, $ archives, m/u/U mark
/// and unmark, B acts on the marked entries, t cycles the TODO state, +/- change the priority, : or
/// C-c C-q sets tags, C-c C-s / C-c C-d schedule and set a deadline, S-→/S-← move the date.
struct AgendaView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    let scheduler: ReminderScheduler?
    let clock: ClockModel
    @State private var agenda: AgendaModel
    @State private var views = AgendaViewLoader.builtIn
    @State private var viewName = AgendaViewLoader.builtIn[0].name
    @State private var matchText = ""
    @State private var selection: String?
    @State private var tick = 0
    /// The view picker moved to the agenda for a followed timestamp, which sets its own days.
    @State private var keepRequestedDays = false
    @State private var message: String?
    @State private var prompt: PendingPrompt?
    @State private var promptText = ""
    @State private var prefix: String?
    /// Entries marked for a bulk action.
    @State private var marked: [EntryRef] = []
    @State private var logMode = false
    @State private var filter = AgendaFilter()
    /// A filter question: its title and which filter it sets.
    @State private var filterPrompt: (title: String, kind: Character)?
    @State private var filterText = ""
    /// A one-line question for an agenda action, and what to do with the answer.
    struct TextPrompt {
        let title: String
        let apply: (String) -> Void
    }
    @State private var textPrompt: TextPrompt?
    @State private var textAnswer = ""
    @AppStorage("agendaSpan") private var span = 10
    @AppStorage("agendaStartOffset") private var startOffset = -3
    @AppStorage("agendaSubfolders") private var includeSubfolders = false
    @AppStorage("agendaPrefixAgenda") private var prefixAgenda = PrefixFormat.defaults["agenda"]!
    @AppStorage("agendaPrefixTodo") private var prefixTodo = PrefixFormat.defaults["todo"]!
    @AppStorage("agendaPrefixTags") private var prefixTags = PrefixFormat.defaults["tags"]!
    @Environment(\.openWindow) private var openWindow

    static let match = "Match…"
    static let todoMatch = "TODO Match…"

    init(workspace: WorkspaceModel, session: DocumentSession, commands: AppCommands, scheduler: ReminderScheduler?, clock: ClockModel) {
        self.workspace = workspace
        self.session = session
        self.commands = commands
        self.scheduler = scheduler
        self.clock = clock
        _agenda = State(initialValue: AgendaModel(workspace: workspace))
    }

    /// An agenda entry by its file, heading line and where that line was.
    struct EntryRef: Hashable {
        let path: String
        let line: String
        let offset: Int

        init?(_ item: AgendaItem) {
            guard let path = item.path, let line = item.headingLine, let offset = item.headingOffset else { return nil }
            self.path = path
            self.line = line
            self.offset = offset
        }
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
        var prefix: [String]
        var logMode: Bool
        var files: Int
        var changed: Int?
        var edits: Int
        var path: String?
        var tick: Int
    }

    private var refreshKey: RefreshKey {
        RefreshKey(
            mode: agenda.mode, start: agenda.start, span: span, startOffset: startOffset, includeSubfolders: includeSubfolders, prefix: [prefixAgenda, prefixTodo, prefixTags], logMode: logMode,
            files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion,
            path: session.path, tick: tick
        )
    }

    private var isAgenda: Bool {
        if case .agenda = agenda.mode { return true }
        return false
    }

    private var isMatch: Bool { viewName == Self.match || viewName == Self.todoMatch }

    private var customPrefix: Bool {
        switch agenda.mode {
        case .agenda: prefixAgenda != PrefixFormat.defaults["agenda"]
        case .todo: prefixTodo != PrefixFormat.defaults["todo"]
        case .match: prefixTags != PrefixFormat.defaults["tags"]
        }
    }

    @Environment(\.orgTheme) private var theme

    var body: some View {
        List(selection: $selection) {
            if isAgenda {
                ForEach(agenda.days, id: \.day) { day in
                    Section {
                        rows(day.items.filter(filter.keeps), prefix: "\(day.day)", day: day.day)
                    } header: {
                        Text(day.header)
                            .font(.headline)
                            .foregroundStyle(day.isToday ? theme.color("agenda-today") ?? .accentColor : theme.color("agenda-date") ?? .primary)
                    }
                }
            } else {
                Section {
                    rows(agenda.list.filter(filter.keeps), prefix: "list")
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
            if let message = message ?? (filter.isEmpty ? reminderStatus : "Filter: " + filter.description) {
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
        .sheet(item: Binding(get: { prompt?.prompt.fast == nil ? nil : prompt }, set: { if $0 == nil { prompt = nil } })) { pending in
            if let fast = pending.prompt.fast {
                FastSelectionView(selection: fast, message: pending.prompt.message) { answer in
                    prompt = nil
                    guard let answer else { return }
                    promptText = answer
                    prompt = pending
                    answerPrompt()
                }
                .frame(minWidth: 420)
            }
        }
        .alert(prompt?.prompt.message ?? "", isPresented: Binding(get: { prompt != nil && prompt?.prompt.fast == nil }, set: { if !$0 { prompt = nil } })) {
            TextField("", text: $promptText)
            Button("OK") { answerPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        } message: {
            if let choices = prompt?.prompt.choices, !choices.isEmpty {
                Text(choices.prefix(12).joined(separator: "  "))
            }
        }
        .alert(filterPrompt?.title ?? "", isPresented: Binding(get: { filterPrompt != nil }, set: { if !$0 { filterPrompt = nil } })) {
            TextField("", text: $filterText)
            Button("Filter") { applyFilter() }
            Button("Cancel", role: .cancel) { filterPrompt = nil }
        } message: {
            if filterPrompt?.kind == "/" || filterPrompt?.kind == "\\" {
                Text(shown.tags.sorted().prefix(20).joined(separator: "  "))
            }
        }
        .alert(textPrompt?.title ?? "", isPresented: Binding(get: { textPrompt != nil }, set: { if !$0 { textPrompt = nil } })) {
            TextField("", text: $textAnswer)
            Button("OK") {
                let pending = textPrompt
                let answer = textAnswer
                textPrompt = nil
                textAnswer = ""
                // A follow-up question opens after this alert closes.
                DispatchQueue.main.async { pending?.apply(answer) }
            }
            Button("Cancel", role: .cancel) {
                textPrompt = nil
                textAnswer = ""
            }
        }
        .navigationTitle(viewName.replacingOccurrences(of: "…", with: ""))
        .onChange(of: viewName) { applyView() }
        .onChange(of: commands.agendaRequest?.start, initial: true) { showRequestedDays() }
        .onChange(of: commands.agendaRequest?.days) { showRequestedDays() }
        .task(id: refreshKey) {
            agenda.span = span
            agenda.startOffset = startOffset
            agenda.includeSubfolders = includeSubfolders
            agenda.options.prefixFormat = ["agenda": prefixAgenda, "todo": prefixTodo, "tags": prefixTags]
            agenda.options.logMode = logMode
            agenda.options = OrgPreferences.agendaOptions(agenda.options)
            let open = session.openTexts
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
            AgendaRow(item: item, day: day, customPrefix: customPrefix, marked: EntryRef(item).map(marked.contains) ?? false)
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

    /// The days of a followed timestamp, in the agenda view.
    private func showRequestedDays() {
        guard let request = commands.agendaRequest else { return }
        commands.agendaRequest = nil
        selection = nil
        if viewName != AgendaViewLoader.builtIn[0].name {
            keepRequestedDays = true
            viewName = AgendaViewLoader.builtIn[0].name
        }
        agenda.mode = .agenda(span: request.days, startOffset: nil)
        agenda.start = request.start
    }

    private func applyView() {
        if keepRequestedDays { return keepRequestedDays = false }
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
        let items = (parts[0] == "list" ? agenda.list : agenda.days.first { "\($0.day)" == parts[0] }?.items ?? []).filter(filter.keeps)
        return index < items.count ? items[index] : nil
    }

    // MARK: - Filters

    /// The tags and categories on the view's lines, which filter words are read against.
    private var shown: (tags: Set<String>, categories: Set<String>) {
        let items = (isAgenda ? agenda.days.flatMap(\.items) : agenda.list).filter { $0.path != nil }
        return (Set(items.flatMap(\.tags)), Set(items.map(\.category)))
    }

    private func askFilter(_ kind: Character) {
        switch kind {
        case "/": filterText = filter.description
        default: filterText = ""
        }
        let title = switch kind {
        case "/": "Filter [+cat-tag<0:10-/regexp/]:"
        case "\\": "Tag filter (+tag-tag):"
        case "=": "Regexp filter (-re to drop):"
        default: "Effort filter (<0:30, >1:00, =1:00):"
        }
        filterPrompt = (title, kind)
    }

    private func applyFilter() {
        guard let kind = filterPrompt?.kind else { return }
        filterPrompt = nil
        let text = filterText.trimmingCharacters(in: .whitespaces)
        var current = filter
        switch kind {
        case "/":
            let (parsed, ignored) = AgendaFilter().parse(text, tags: shown.tags, categories: shown.categories)
            current = parsed
            if !ignored.isEmpty { message = "\(ignored.joined(separator: " ")) ignored: no line has that tag or category" }
        case "\\":
            // Every word as a tag.
            current.tags = AgendaFilter().parse(text, tags: Set(text.split(whereSeparator: { "+- ".contains($0) }).map(String.init)), categories: []).filter.tags
        case "=":
            current.regexps = text.isEmpty ? [] : [text.hasPrefix("-") || text.hasPrefix("+") ? text : "+" + text]
        default:
            current.efforts = text.isEmpty ? [] : ["+" + text]
        }
        filter = current
        selection = nil
    }

    /// `<`: keep only the selected line's category, or drop that filter.
    private func toggleCategoryFilter() {
        if !filter.categories.isEmpty {
            filter.categories = []
        } else if let selection, let item = item(selection) {
            filter.categories = ["+" + item.category]
        } else {
            message = "No entry selected"
        }
    }

    private func jump(_ id: String) {
        guard let item = item(id), let path = item.path, let offset = item.markerOffset ?? item.headingOffset else { return }
        commands.jump(path: path, offset: offset)
        openWindow(id: "main")
    }

    // MARK: - Commands

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let control = press.modifiers.contains(.control)
        // `C-x` and friends arrive as control characters or as letters with control.
        func isControl(_ letter: String, _ code: String) -> Bool { control && (press.characters == letter || press.characters == code) }
        if let pending = prefix {
            prefix = nil
            if pending == "C-c C-x" {
                if isControl("s", "\u{13}") { archive() } else { message = "C-c C-x \(press.characters) is undefined" }
                return .handled
            }
            if isControl("s", "\u{13}") {
                run(SetPlanning(deadline: false))
            } else if isControl("d", "\u{04}") {
                run(SetPlanning(deadline: true))
            } else if isControl("q", "\u{11}") {
                run(SetTags())
            } else if isControl("t", "\u{14}") {
                run(TodoCycle())
            } else if isControl("w", "\u{17}") {
                refile(marked: false)
            } else if isControl("x", "\u{18}") {
                prefix = "C-c C-x"
                message = "C-c C-x-"
            } else if press.characters == "$" {
                archive()
            } else {
                message = "C-c \(press.characters) is undefined"
            }
            return .handled
        }
        if isControl("c", "\u{03}") {
            prefix = "C-c"
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
        case "/", "\\", "=", "_": askFilter(press.characters.first!)
        case "<": toggleCategoryFilter()
        case "|":
            filter = AgendaFilter()
            message = "Filters removed"
        case "l" where isAgenda:
            logMode.toggle()
            message = logMode ? "Log mode on" : "Log mode off"
        case "g", "r":
            loadViews()
            tick += 1
        case "I": clockIn()
        case "O": message = clock.clockOut(session)
        case "X": message = clock.clockOut(session, cancel: true)
        case "$": archive()
        case "m": mark(true)
        case "u": mark(false)
        case "U":
            marked = []
            message = "No entries marked"
        case "B": askBulk()
        case "t": run(TodoCycle())
        case "+": run(PriorityUp())
        case "-": run(PriorityDown())
        case ":": run(SetTags())
        default: return .ignored
        }
        return .handled
    }

    // MARK: - Clock, refile, archive, bulk

    private var selectedEntry: EntryRef? { selection.flatMap(item).flatMap(EntryRef.init) }

    private func clockIn() {
        guard let entry = selectedEntry, let offset = session.locateHeading(path: entry.path, line: entry.line, near: entry.offset) else {
            message = "No entry selected"
            return
        }
        let paths = workspace.files.filter { $0.kind == .org }.map(\.path)
        Task {
            let outcome = await clock.clockIn(session, target: .entry(path: entry.path, offset: offset), paths: paths, ask: commands.askClock)
            if let jump = outcome.jump { commands.jump(path: jump.path, offset: jump.offset) }
            message = outcome.messages.last { !$0.isEmpty }
            tick += 1
        }
    }

    private func archive() {
        guard let entry = selectedEntry, let offset = session.locateHeading(path: entry.path, line: entry.line, near: entry.offset) else {
            message = "No entry selected"
            return
        }
        message = session.archive(from: (entry.path, offset))
        tick += 1
    }

    /// Refiles the selected entry, or with `marked` the marked ones, to a target asked for in
    /// the main window, where the list of targets is searchable.
    private func refile(marked bulk: Bool) {
        let entries = bulk ? marked : selectedEntry.map { [$0] } ?? []
        guard !entries.isEmpty else {
            message = "No entry selected"
            return
        }
        let targets = workspace.refileTargets(openPath: session.path, document: session.document)
        commands.ask(Prompt(key: "refile", message: "Refile to:", choices: targets.map(\.label))) { answer in
            guard let answer, targets.contains(where: { $0.label == answer }) else { return }
            message = eachEntry(entries) { entry, offset in
                // Targets in the entry's own file from its text now, as earlier moves shift them.
                let document = session.openDocuments.first { $0.path == entry.path }?.document
                    ?? FileManager.default.contents(atPath: entry.path).map { DocumentState(bytes: [UInt8]($0)) }
                guard let target = workspace.refileTargets(openPath: entry.path, document: document).first(where: { $0.label == answer }) else {
                    return "Can't find \(answer) any more."
                }
                return session.refile(to: target, from: (entry.path, offset))
            }
            if bulk { marked = [] }
            tick += 1
        }
        openWindow(id: "main")
    }

    /// Runs `action` on each entry, finding it again first: later entries in a file first, so
    /// earlier ones keep their place. Returns the last message.
    private func eachEntry(_ entries: [EntryRef], _ action: (EntryRef, Int) -> String?) -> String? {
        var last: String?
        var failed = 0
        for entry in entries.sorted(by: { ($0.path, $1.offset) < ($1.path, $0.offset) }) {
            guard let offset = session.locateHeading(path: entry.path, line: entry.line, near: entry.offset) else {
                failed += 1
                continue
            }
            last = action(entry, offset)
        }
        return failed > 0 ? "\(failed) marked \(failed == 1 ? "entry" : "entries") changed and \(failed == 1 ? "was" : "were") skipped" : last
    }

    private func mark(_ on: Bool) {
        guard let entry = selectedEntry else {
            message = "No entry selected"
            return
        }
        if on {
            if !marked.contains(entry) { marked.append(entry) }
        } else {
            marked.removeAll { $0 == entry }
        }
        message = "\(marked.count) marked"
    }

    /// `B`: an action for every marked entry.
    private func askBulk() {
        guard !marked.isEmpty else {
            message = "No entries are marked"
            return
        }
        textPrompt = TextPrompt(title: "Bulk action on \(marked.count): [$] archive [r] refile [t] TODO state [+] tag [-] untag [s] schedule [d] deadline") { answer in
            switch answer.trimmingCharacters(in: .whitespaces) {
            case "$": bulk { session.archive(from: ($0.path, $1)) }
            case "r": refile(marked: true)
            case "t":
                textPrompt = TextPrompt(title: "TODO state (empty for none):") { keyword in
                    let word = keyword.trimmingCharacters(in: .whitespaces)
                    bulk { performAt($0, $1, SetTodo(keyword: word.isEmpty ? nil : word)) }
                }
            case "+", "-":
                let on = answer.trimmingCharacters(in: .whitespaces) == "+"
                textPrompt = TextPrompt(title: on ? "Tag to add:" : "Tag to remove:") { tag in
                    let tag = tag.trimmingCharacters(in: .whitespaces)
                    guard !tag.isEmpty else { return }
                    bulk { performAt($0, $1, ToggleTag(tag: tag, on: on)) }
                }
            case "s", "d":
                let deadline = answer.trimmingCharacters(in: .whitespaces) == "d"
                textPrompt = TextPrompt(title: deadline ? "Deadline (+2d, fri, 2026-10-12):" : "Schedule (+2d, fri, 2026-10-12):") { date in
                    bulk { performAt($0, $1, SetPlanning(deadline: deadline), answers: ["date": date]) }
                }
            default:
                message = "No bulk action \(answer)"
            }
        }
    }

    private func bulk(_ action: (EntryRef, Int) -> String?) {
        message = eachEntry(marked, action) ?? "Done with \(marked.count) entries"
        marked = []
        tick += 1
    }

    /// Runs `command` at the heading at `offset`, as `run` does for the selection.
    private func performAt(_ entry: EntryRef, _ offset: Int, _ command: any OrgCommand, answers: [String: String] = [:]) -> String? {
        switch session.perform(command, path: entry.path, at: offset, expect: (offset, entry.line), answers: answers) {
        case .failed(let text): text
        case .prompt: "\(command.title) needs an answer; run it on the entry itself"
        default: nil
        }
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
    /// A user `org-agenda-prefix-format`: the prefix as Emacs prints it, not the columns.
    var customPrefix = false
    /// Marked for a bulk action.
    var marked = false
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
            HStack(spacing: 4) {
                if marked { Text("›").bold().foregroundStyle(theme.color("agenda-today") ?? .accentColor) }
                entryRow
            }
        }
    }

    @ViewBuilder
    private var entryRow: some View {
            if customPrefix {
                HStack(spacing: 0) {
                    Text(item.prefix)
                        .font(.body.monospaced())
                        .foregroundStyle(theme.color("agenda-category") ?? .secondary)
                    title.lineLimit(1)
                    Spacer(minLength: 8)
                    if let habit = item.habit, let day { HabitGraph(cells: habit.graph(today: day), theme: theme) }
                    if !item.tags.isEmpty {
                        Text(":" + item.tags.joined(separator: ":") + ":").font(.caption).foregroundStyle(theme.color("tags") ?? .secondary)
                    }
                }
            } else {
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
        let todo_ = Text(todo).foregroundColor(theme.keywordColor(todo, done: item.isDone)).bold()
        return Text("\(todo_)\(rest_)")
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
