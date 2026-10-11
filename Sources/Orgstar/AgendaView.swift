import AppKit
import OrgApp
import OrgDocument
import OrgCore
import OrgPresentation
import SwiftUI

/// The days an agenda shows, as Org's `v d`, `v w` and `v m`.
enum AgendaSpan: String, CaseIterable {
    case day, week, month
}

/// The app's one reader of Calendar events and of Reminders, for the agenda and Settings.
@MainActor
enum CalendarAccess {
    static let events = CalendarEvents()
    static let reminders = ReminderLists()
}

/// The agenda window: the day/week agenda, the TODO list, tag matches, text search and saved views.
/// Return or a double click jumps to the entry in the main window. Keys as in Emacs's agenda:
/// n/p (or the arrows) move between lines, f/b/. move the span, j picks a date, v d/v w/v m (or
/// d/w) show a day, week or month, g refreshes, l shows the log (closed and clocked), / filters
/// (`+cat-tag<0:10-/regexp/`), \ by tag, < by the line's category, = by regexp, _ by effort,
/// | clears filters, I/O/X clock in, out and cancel, C-c C-w refiles, $ archives, m/u/U mark
/// and unmark, B acts on the marked entries, t cycles the TODO state, +/- change the priority and
/// , sets it, : or C-c C-q sets tags, C-c C-s / C-c C-d schedule and set a deadline, S-→/S-← move
/// the date, k captures on the line's day, s saves all files, TAB and SPC show the entry.
struct AgendaView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    let scheduler: ReminderScheduler?
    let clock: ClockModel
    @State var agenda: AgendaModel
    @State var views = AgendaViewLoader.builtIn
    @State var viewName = AgendaViewLoader.builtIn[0].name
    @State var matchText = ""
    /// The selected line: `day:index` (`day:o` + index in the overdue group), or `list:index`.
    @State var selection: String?
    @State var tick = 0
    /// The time the now line shows, kept to the minute while the agenda is open.
    @State var now = Date()
    /// The view picker moved to the agenda for a followed timestamp, which sets its own days.
    @State var keepRequestedDays = false
    @State var message: String?
    @State var prompt: PendingPrompt?
    /// An event being changed, or an entry being added to a calendar.
    @State private var eventRequest: EventRequest?
    @State var promptText = ""
    @State var prefix: String?
    /// Entries marked for a bulk action.
    @State var marked: [EntryRef] = []
    @State var logMode = false
    @State var filter = AgendaFilter()
    /// A filter question: its title and which filter it sets.
    @State var filterPrompt: (title: String, kind: Character)?
    @State var filterText = ""
    /// A one-line question for an agenda action, and what to do with the answer.
    struct TextPrompt {
        let title: String
        let apply: (String) -> Void
    }
    @State var textPrompt: TextPrompt?
    @State private var textAnswer = ""
    /// Day, week or month chosen with `v`; nil shows the span the settings or the view give.
    @State var spanKind: AgendaSpan?
    @State var showingDatePicker = false
    @State var pickedDate = Date()
    @AppStorage("agendaOverdueExpanded") private var overdueShown = true
    @State private var hovered: String?
    @FocusState private var focused: Bool
    @AppStorage("agendaSpan") var span = 10
    @AppStorage("agendaStartOffset") var startOffset = 0
    @AppStorage("agendaStartOnWeekday") private var startOnWeekday = "1"
    @AppStorage("agendaSubfolders") private var includeSubfolders = false
    @AppStorage("agendaFiles") private var agendaFileList = ""
    @AppStorage("agendaShowAllDates") private var showAllDates = false
    @AppStorage("calendarEvents") private var calendarEventsOn = false
    @AppStorage("calendarEventCalendars") private var calendarNames = ""
    @AppStorage("agendaReminders") private var remindersOn = false
    @AppStorage("agendaReminderLists") private var reminderListNames = ""
    @AppStorage("agendaPrefixAgenda") private var prefixAgenda = PrefixFormat.defaults["agenda"]!
    @AppStorage("agendaPrefixTodo") private var prefixTodo = PrefixFormat.defaults["todo"]!
    @AppStorage("agendaPrefixTags") private var prefixTags = PrefixFormat.defaults["tags"]!
    @AppStorage("agendaSortAgenda") private var sortAgenda = ""
    @AppStorage("agendaSortTodo") private var sortTodo = ""
    @AppStorage("agendaSortTags") private var sortTags = ""
    @AppStorage("agendaSortSearch") private var sortSearch = ""
    @AppStorage("agendaUseTimeGrid") private var useTimeGrid = true
    @AppStorage("agendaShowCurrentTime") private var showCurrentTime = true
    @AppStorage("agendaTimeGridWhen") private var gridWhen = ""
    @AppStorage("agendaTimeGridTimes") private var gridTimes = ""
    @AppStorage("stuckProjectsMatch") private var stuckMatch = ""
    @AppStorage("stuckProjectsTodo") private var stuckTodo = ""
    @AppStorage("stuckProjectsTags") private var stuckTags = ""
    @AppStorage("stuckProjectsRegexp") private var stuckRegexp = ""
    @Environment(\.openWindow) var openWindow

    static let match = "Match…"
    static let todoMatch = "TODO Match…"
    static let search = "Search…"
    static let todoSearch = "TODO Search…"

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
        var startOnWeekday: String
        var includeSubfolders: Bool
        var prefix: [String]
        var settings: [String]
        var logMode: Bool
        var calendars: [String]
        var files: Int
        var changed: Int?
        var edits: Int
        var path: String?
        var tick: Int
    }

    /// The settings part of the refresh key; `Refresher` adds the files and edits, so that
    /// they redraw only it.
    private var refreshKey: RefreshKey {
        RefreshKey(
            mode: agenda.mode, start: agenda.start, span: span, startOffset: startOffset, startOnWeekday: startOnWeekday, includeSubfolders: includeSubfolders, prefix: [prefixAgenda, prefixTodo, prefixTags],
            settings: [sortAgenda, sortTodo, sortTags, sortSearch, gridWhen, gridTimes, "\(useTimeGrid) \(showCurrentTime)", stuckMatch, stuckTodo, stuckTags, stuckRegexp, agendaFileList],
            logMode: logMode,
            calendars: (calendarEventsOn ? [calendarNames] : []) + (remindersOn ? ["reminders", reminderListNames] : []), files: 0, changed: nil, edits: 0, path: nil, tick: tick
        )
    }

    private func refresh() async {
        agenda.span = span
        agenda.startOffset = startOffset
        agenda.startOnWeekday = Int(startOnWeekday)
        agenda.includeSubfolders = includeSubfolders
        agenda.agendaFiles = OrgPreferences.agendaFiles()
        agenda.options.prefixFormat = ["agenda": prefixAgenda, "todo": prefixTodo, "tags": prefixTags]
        agenda.options.logMode = logMode
        agenda.options = OrgPreferences.agendaOptions(agenda.options)
        agenda.calendarNames = OrgPreferences.calendarEventCalendars()
        if calendarEventsOn, isAgenda || isBlocks {
            agenda.calendarEvents = await CalendarAccess.events.requestAccess() ? CalendarAccess.events : nil
        } else {
            agenda.calendarEvents = nil
        }
        agenda.reminderListNames = OrgPreferences.agendaReminderLists()
        if remindersOn, isAgenda || isBlocks {
            agenda.reminderLists = await CalendarAccess.reminders.requestAccess() ? CalendarAccess.reminders : nil
        } else {
            agenda.reminderLists = nil
        }
        await agenda.refresh(open: session.openTexts)
    }

    /// Refreshes the agenda when the settings, files or edits change, once a burst of them ends.
    private struct Refresher: View {
        let base: RefreshKey
        let session: DocumentSession
        let workspace: WorkspaceModel
        let refresh: () async -> Void

        var key: RefreshKey {
            var key = base
            key.files = workspace.files.count
            key.changed = workspace.changedFile?.version
            key.edits = session.editVersion
            key.path = session.path
            return key
        }

        var body: some View {
            Color.clear.task(id: key) {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    var isAgenda: Bool {
        if case .agenda = agenda.mode { return true }
        return false
    }

    var isBlocks: Bool {
        if case .blocks = agenda.mode { return true }
        return false
    }

    var isMatch: Bool { viewName == Self.match || viewName == Self.todoMatch }
    var isSearch: Bool { viewName == Self.search || viewName == Self.todoSearch }

    @Environment(\.orgTheme) private var theme

    // MARK: - Lines

    /// A selectable line: its selection id, the row, and the day it is on.
    struct Line {
        let id: String
        let row: AgendaRow
        let day: Int
    }

    private var groups: [AgendaDayGroup] {
        isAgenda ? agenda.groups(showAllDates: showAllDates, filter: filter) : []
    }

    private var listRows: [AgendaRow] { rows(agenda.list) }

    private func rows(_ list: [AgendaItem]) -> [AgendaRow] {
        list.filter(filter.keeps).compactMap { AgendaRow(item: $0, day: agenda.today, today: agenda.today) }
    }

    /// The lines in order, as up and down move through them.
    func lines(_ groups: [AgendaDayGroup]) -> [Line] {
        if isBlocks {
            return agenda.blocks.enumerated().flatMap { k, block in
                block.isAgenda ? dayLines(agenda.groups(block, showAllDates: showAllDates, filter: filter), prefix: "b\(k):")
                    : rows(block.list).enumerated().map { Line(id: "b\(k):list:\($0.offset)", row: $0.element, day: agenda.today) }
            }
        }
        guard isAgenda else { return listRows.enumerated().map { Line(id: "list:\($0.offset)", row: $0.element, day: agenda.today) } }
        return dayLines(groups, prefix: "")
    }

    private func dayLines(_ groups: [AgendaDayGroup], prefix: String) -> [Line] {
        groups.flatMap { group in
            (overdueShown ? group.overdue.enumerated().map { Line(id: "\(prefix)\(group.day):o\($0.offset)", row: $0.element, day: group.day) } : [])
                + group.rows.enumerated().map { Line(id: "\(prefix)\(group.day):\($0.offset)", row: $0.element, day: group.day) }
        }
    }

    func line(_ id: String) -> Line? { lines(groups).first { $0.id == id } }

    var body: some View {
        let groups = self.groups
        _ = tick
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if isBlocks {
                        ForEach(Array(agenda.blocks.enumerated()), id: \.offset) { k, block in
                            Section {
                                if block.isAgenda {
                                    ForEach(agenda.groups(block, showAllDates: showAllDates, filter: filter)) { group in
                                        dayHeader(group)
                                        dayRows(group, prefix: "b\(k):")
                                    }
                                } else {
                                    ForEach(Array(rows(block.list).enumerated()), id: \.offset) { index, row in
                                        rowView(Line(id: "b\(k):list:\(index)", row: row, day: agenda.today), showsGutter: false)
                                    }
                                }
                            } header: {
                                header { Text(block.header).font(.system(size: 13, weight: .semibold)) }
                            }
                        }
                    } else if isAgenda {
                        ForEach(groups) { group in
                            Section {
                                dayRows(group)
                            } header: {
                                dayHeader(group).id("day\(group.day)")
                            }
                        }
                    } else {
                        Section {
                            ForEach(Array(listRows.enumerated()), id: \.offset) { index, row in
                                rowView(Line(id: "list:\(index)", row: row, day: agenda.today), showsGutter: false)
                            }
                        } header: {
                            header { Text(listTitle).font(.system(size: 13, weight: .semibold)) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .onChange(of: selection) {
                if let selection { proxy.scrollTo(selection) }
            }
            .onChange(of: agenda.days.first?.day) {
                if groups.contains(where: \.isToday) { proxy.scrollTo("day\(agenda.today)", anchor: .top) }
            }
        }
        .background(theme.color("agenda-background") ?? Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
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
        .toolbar { toolbar }
        .overlay {
            if agenda.files.isEmpty {
                ContentUnavailableView("No agenda files", systemImage: "calendar", description: Text("The agenda reads the org files at the top of each folder you add."))
            }
        }
        .sheet(item: $eventRequest) { request in
            EventSheet(request: request, events: CalendarAccess.events) { result in
                eventRequest = nil
                if let result {
                    message = result
                    tick += 1
                }
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
        .navigationTitle(title)
        .navigationSubtitle(isAgenda && viewName != AgendaViewLoader.builtIn[0].name ? viewName : "")
        .onChange(of: viewName) { applyView() }
        .onChange(of: commands.agendaRequest?.start, initial: true) { showRequestedDays() }
        .onChange(of: commands.agendaRequest?.days) { showRequestedDays() }
        .background { Refresher(base: refreshKey, session: session, workspace: workspace, refresh: refresh) }
        .task {
            loadViews()
            // The now line moves each minute; a new day refreshes the statuses.
            while !Task.isCancelled {
                let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
                try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow))
                now = Date()
                if Days.absolute(now, calendar: .current) != agenda.today { tick += 1 }
            }
        }
    }

    // MARK: - Days

    private var todayColor: Color { theme.color("agenda-today") ?? .accentColor }

    @ViewBuilder
    private func dayRows(_ group: AgendaDayGroup, prefix: String = "") -> some View {
        if group.isToday, !group.overdue.isEmpty {
            overdueHeader(count: group.overdue.count)
            if overdueShown {
                ForEach(Array(group.overdue.enumerated()), id: \.element.id) { index, row in
                    rowView(Line(id: "\(prefix)\(group.day):o\(index)", row: row, day: group.day))
                }
                Divider().padding(.leading, 16).padding(.vertical, 4)
            }
        }
        if group.isEmpty {
            Text("Nothing scheduled")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        ForEach(Array(group.lines(now: Self.hhmm(now)).enumerated()), id: \.offset) { _, line in
            switch line {
            case .row(let index): rowView(Line(id: "\(prefix)\(group.day):\(index)", row: group.rows[index], day: group.day))
            case .grid(let time): gridLine(time)
            case .now: nowLine
            }
        }
    }

    /// An `org-agenda-time-grid` line.
    private func gridLine(_ time: Int) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d:%02d", time / 100, time % 100))
                .font(.system(size: 10).monospacedDigit())
                .frame(width: AgendaRowView.gutterWidth, alignment: .leading)
            GridRule().stroke(style: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).frame(height: 1)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private func header(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 16)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("agenda-background") ?? Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
    }

    private func dayHeader(_ group: AgendaDayGroup) -> some View {
        let past = group.day < agenda.today
        let color = group.isToday ? todayColor : past ? Color.secondary : theme.color("agenda-date") ?? .primary
        return header {
            if let relative = group.relativeName(today: agenda.today) {
                Text(relative)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
                Text("·").foregroundStyle(.tertiary)
            }
            Text(Self.format(group.day, Days.date(group.day).year == Days.date(agenda.today).year ? "EEEE d MMMM" : "EEEE d MMMM yyyy"))
                .font(.system(size: 13, weight: group.isToday ? .bold : .semibold))
                .foregroundStyle(color)
            Spacer()
            Button {
                capture(on: group.day)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(group.isToday ? todayColor : .secondary)
            .help("Capture an entry scheduled on this day (k)")
        }
    }

    private func overdueHeader(count: Int) -> some View {
        let color = theme.dynamic(.systemRed) { [theme] in theme.statusColor(.overdue, dark: $0) }
        return Button {
            withAnimation(.snappy(duration: 0.2)) { overdueShown.toggle() }
            if !overdueShown, selection?.contains(":o") == true { selection = nil }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(overdueShown ? 90 : 0))
                Text("Overdue").font(.system(size: 12, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(0.15)))
                Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(overdueShown ? "Hide entries from earlier days" : "Show entries from earlier days")
    }

    private var nowLine: some View {
        HStack(spacing: 6) {
            Text(now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .frame(width: AgendaRowView.gutterWidth, alignment: .leading)
            Circle().frame(width: 6, height: 6)
            Rectangle().frame(height: 1)
        }
        .foregroundStyle(todayColor)
        .padding(.horizontal, 16)
        .frame(height: 10)
        .accessibilityLabel("Now")
    }

    private func rowView(_ line: Line, showsGutter: Bool = true) -> some View {
        AgendaRowView(
            row: line.row, day: line.day, showsGutter: showsGutter, selected: selection == line.id, hovered: hovered == line.id,
            marked: line.row.item.flatMap(EntryRef.init).map(marked.contains) ?? false
        )
        .id(line.id)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
        }
        .onTapGesture(count: 2) { open(line) }
        .simultaneousGesture(TapGesture().onEnded {
            selection = line.id
            focused = true
        })
        .contextMenu { menu(line) }
    }

    @ViewBuilder
    private func menu(_ line: Line) -> some View {
        if let event = line.row.event {
            Button(event.isReminder ? "Show in Reminders" : "Show in Calendar") { openEvent(event) }
            if !event.isReminder {
                Button("Edit Event…") { eventRequest = EventRequest(draft: EventDraft(event), event: event) }
            }
        } else if line.row.item != nil {
            Button("Open") { selection = line.id; jump(line.id) }
            Divider()
            Button("Cycle TODO State") { selection = line.id; run(TodoCycle()) }
            Button("Set Priority…") { selection = line.id; run(SetPriority()) }
            Button("Set Tags…") { selection = line.id; run(SetTags()) }
            Button("Schedule…") { selection = line.id; run(SetPlanning(deadline: false)) }
            Button("Set Deadline…") { selection = line.id; run(SetPlanning(deadline: true)) }
            Divider()
            Button("Add to Calendar…") {
                eventRequest = EventRequest(draft: .entry(line.row.title, day: line.day, start: line.row.start, end: line.row.end))
            }
            Divider()
            Button("Clock In") { selection = line.id; clockIn() }
            Button(EntryRef(line.row.item!).map(marked.contains) == true ? "Unmark" : "Mark") {
                selection = line.id
                mark(!(EntryRef(line.row.item!).map(marked.contains) ?? false))
            }
            Button("Archive") { selection = line.id; archive() }
        }
    }

    @AppStorage("reminders") var remindersEnabled = true

    // MARK: - Items

    func item(_ id: String) -> AgendaItem? { line(id)?.row.item }

    /// Return and double click: the entry in the main window, or the event in Calendar or Reminders.
    func open(_ line: Line) {
        selection = line.id
        if let event = line.row.event { openEvent(event) } else { jump(line.id) }
    }

    /// Calendar shows an event from its identifier (`AgendaEvent.id` adds `@` and the start);
    /// Reminders a reminder from its own.
    private func openEvent(_ event: AgendaEvent) {
        if event.isReminder {
            if let url = URL(string: "x-apple-reminderkit://REMCDReminder/\(event.id)") { NSWorkspace.shared.open(url) }
            return
        }
        let identifier = event.id.split(separator: "@").dropLast().joined(separator: "@")
        guard !identifier.isEmpty, let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Moves the selection by `step` lines.
    func step(_ step: Int) {
        let all = lines(groups)
        guard !all.isEmpty else { return }
        let index = selection.flatMap { id in all.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + step, 0), all.count - 1) } ?? (step > 0 ? 0 : all.count - 1)
        selection = all[next].id
    }
}

/// A horizontal line through the middle of its frame.
struct GridRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
