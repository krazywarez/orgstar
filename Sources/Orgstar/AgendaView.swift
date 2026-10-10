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

/// The app's one reader of Calendar events, for the agenda and Settings.
@MainActor
enum CalendarAccess {
    static let events = CalendarEvents()
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
    @State private var agenda: AgendaModel
    @State private var views = AgendaViewLoader.builtIn
    @State private var viewName = AgendaViewLoader.builtIn[0].name
    @State private var matchText = ""
    /// The selected line: `day:index` (`day:o` + index in the overdue group), or `list:index`.
    @State private var selection: String?
    @State private var tick = 0
    /// The time the now line shows, kept to the minute while the agenda is open.
    @State private var now = Date()
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
    /// Day, week or month chosen with `v`; nil shows the span the settings or the view give.
    @State private var spanKind: AgendaSpan?
    @State private var showingDatePicker = false
    @State private var pickedDate = Date()
    @AppStorage("agendaOverdueExpanded") private var overdueShown = true
    @State private var hovered: String?
    @FocusState private var focused: Bool
    @AppStorage("agendaSpan") private var span = 10
    @AppStorage("agendaStartOffset") private var startOffset = -3
    @AppStorage("agendaSubfolders") private var includeSubfolders = false
    @AppStorage("agendaShowAllDates") private var showAllDates = false
    @AppStorage("calendarEvents") private var calendarEventsOn = false
    @AppStorage("calendarEventCalendars") private var calendarNames = ""
    @AppStorage("agendaPrefixAgenda") private var prefixAgenda = PrefixFormat.defaults["agenda"]!
    @AppStorage("agendaPrefixTodo") private var prefixTodo = PrefixFormat.defaults["todo"]!
    @AppStorage("agendaPrefixTags") private var prefixTags = PrefixFormat.defaults["tags"]!
    @Environment(\.openWindow) private var openWindow

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
        var includeSubfolders: Bool
        var prefix: [String]
        var logMode: Bool
        var calendars: [String]
        var files: Int
        var changed: Int?
        var edits: Int
        var path: String?
        var tick: Int
    }

    private var refreshKey: RefreshKey {
        RefreshKey(
            mode: agenda.mode, start: agenda.start, span: span, startOffset: startOffset, includeSubfolders: includeSubfolders, prefix: [prefixAgenda, prefixTodo, prefixTags], logMode: logMode,
            calendars: calendarEventsOn ? [calendarNames] : [], files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion,
            path: session.path, tick: tick
        )
    }

    private var isAgenda: Bool {
        if case .agenda = agenda.mode { return true }
        return false
    }

    private var isMatch: Bool { viewName == Self.match || viewName == Self.todoMatch }
    private var isSearch: Bool { viewName == Self.search || viewName == Self.todoSearch }

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

    private var listRows: [AgendaRow] {
        isAgenda ? [] : agenda.list.filter(filter.keeps).compactMap { AgendaRow(item: $0, day: agenda.today, today: agenda.today) }
    }

    /// The lines in order, as up and down move through them.
    private func lines(_ groups: [AgendaDayGroup]) -> [Line] {
        guard isAgenda else { return listRows.enumerated().map { Line(id: "list:\($0.offset)", row: $0.element, day: agenda.today) } }
        return groups.flatMap { group in
            (overdueShown ? group.overdue.enumerated().map { Line(id: "\(group.day):o\($0.offset)", row: $0.element, day: group.day) } : [])
                + group.rows.enumerated().map { Line(id: "\(group.day):\($0.offset)", row: $0.element, day: group.day) }
        }
    }

    private func line(_ id: String) -> Line? { lines(groups).first { $0.id == id } }

    var body: some View {
        let groups = self.groups
        _ = tick
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if isAgenda {
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
        .task(id: refreshKey) {
            agenda.span = span
            agenda.startOffset = startOffset
            agenda.includeSubfolders = includeSubfolders
            agenda.options.prefixFormat = ["agenda": prefixAgenda, "todo": prefixTodo, "tags": prefixTags]
            agenda.options.logMode = logMode
            agenda.options = OrgPreferences.agendaOptions(agenda.options)
            agenda.calendarNames = OrgPreferences.calendarEventCalendars()
            if calendarEventsOn, isAgenda {
                agenda.calendarEvents = await CalendarAccess.events.requestAccess() ? CalendarAccess.events : nil
            } else {
                agenda.calendarEvents = nil
            }
            let open = session.openTexts
            await agenda.refresh(open: open)
        }
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
    private func dayRows(_ group: AgendaDayGroup) -> some View {
        if group.isToday, !group.overdue.isEmpty {
            overdueHeader(count: group.overdue.count)
            if overdueShown {
                ForEach(Array(group.overdue.enumerated()), id: \.element.id) { index, row in
                    rowView(Line(id: "\(group.day):o\(index)", row: row, day: group.day))
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
        let nowAt = group.nowIndex(now: Self.hhmm(now))
        ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
            if index == nowAt { nowLine }
            rowView(Line(id: "\(group.day):\(index)", row: row, day: group.day))
        }
        if let nowAt, nowAt == group.rows.count { nowLine }
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
            Button("Show in Calendar") { openEvent(event) }
        } else if line.row.item != nil {
            Button("Open") { selection = line.id; jump(line.id) }
            Divider()
            Button("Cycle TODO State") { selection = line.id; run(TodoCycle()) }
            Button("Set Priority…") { selection = line.id; run(SetPriority()) }
            Button("Set Tags…") { selection = line.id; run(SetTags()) }
            Button("Schedule…") { selection = line.id; run(SetPlanning(deadline: false)) }
            Button("Set Deadline…") { selection = line.id; run(SetPlanning(deadline: true)) }
            Divider()
            Button("Clock In") { selection = line.id; clockIn() }
            Button(EntryRef(line.row.item!).map(marked.contains) == true ? "Unmark" : "Mark") {
                selection = line.id
                mark(!(EntryRef(line.row.item!).map(marked.contains) ?? false))
            }
            Button("Archive") { selection = line.id; archive() }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(views) { view in Button(view.name) { viewName = view.name } }
                Divider()
                Button(Self.match) { viewName = Self.match }
                Button(Self.todoMatch) { viewName = Self.todoMatch }
                Button(Self.search) { viewName = Self.search }
                Button(Self.todoSearch) { viewName = Self.todoSearch }
            } label: {
                Label(viewName, systemImage: "calendar").labelStyle(.titleAndIcon)
            }
            .help("What the agenda shows")
            if isMatch || isSearch {
                TextField(isSearch ? "Phrase or +word -word {regexp}" : "+work-boss|LEVEL>2/!TODO", text: $matchText)
                    .frame(minWidth: 220)
                    .onSubmit { applyView() }
            }
        }
        ToolbarItemGroup {
            if agenda.isComputing { ProgressView().controlSize(.small) }
            if isAgenda {
                Picker("Span", selection: Binding(get: { spanKind }, set: { if let kind = $0 { setSpan(kind) } })) {
                    Text("Day").tag(AgendaSpan?.some(.day))
                    Text("Week").tag(AgendaSpan?.some(.week))
                    Text("Month").tag(AgendaSpan?.some(.month))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Show a day, week or month (v d, v w, v m)")
                ControlGroup {
                    Button("Earlier", systemImage: "chevron.left") { move(forward: false) }
                        .help("Previous days (b)")
                    Button("Today") { goToday() }
                        .help("Back to today (.)")
                    Button("Later", systemImage: "chevron.right") { move(forward: true) }
                        .help("Next days (f)")
                }
                Button("Go to Date", systemImage: "calendar") {
                    pickedDate = Self.date(anchorDay)
                    showingDatePicker = true
                }
                .help("Go to a date (j)")
                .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
                    DatePicker("Date", selection: $pickedDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding()
                        .onChange(of: pickedDate) {
                            showingDatePicker = false
                            goTo(Days.absolute(pickedDate, calendar: .current))
                        }
                }
            }
            Menu {
                Button("Filter…") { askFilter("/") }
                Button("By Tag…") { askFilter("\\") }
                Button("By Category of Selected Line") { toggleCategoryFilter() }
                Button("By Regexp…") { askFilter("=") }
                Button("By Effort…") { askFilter("_") }
                Divider()
                Button("Remove Filters") { filter = AgendaFilter() }
                    .disabled(filter.isEmpty)
            } label: {
                Label("Filter", systemImage: filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            } primaryAction: {
                askFilter("/")
            }
            .help("Filter the entries (/, \\, <, =, _; | removes)")
        }
    }

    /// The span shown, as the window's title: `Week of 5 Oct 2026`.
    private var title: String {
        guard isAgenda else { return viewName.replacingOccurrences(of: "…", with: "") }
        guard let first = agenda.days.first?.day, let last = agenda.days.last?.day else { return "Agenda" }
        switch spanKind {
        case .day: return Self.format(first, "EEEE d MMMM yyyy")
        case .week: return "Week of " + Self.format(first, "d MMM yyyy")
        case .month: return Self.format(first, "MMMM yyyy")
        case nil:
            if first == last { return Self.format(first, "EEEE d MMMM yyyy") }
            let sameYear = Days.date(first).year == Days.date(last).year
            return Self.format(first, sameYear ? "d MMM" : "d MMM yyyy") + " – " + Self.format(last, "d MMM yyyy")
        }
    }

    // MARK: - Span

    /// The day `v`, `j` and `k` start from: the selected line's, else today when shown, else the first.
    private var anchorDay: Int {
        if let selection, let day = Int(selection.prefix { $0 != ":" }) { return day }
        let days = agenda.days.map(\.day)
        if days.contains(agenda.today) || days.isEmpty { return agenda.today }
        return days[0]
    }

    /// `org-agenda-day-view`, `-week-view`, `-month-view`: the day, the week from Monday
    /// (`org-agenda-start-on-weekday`), or the month around `anchor`.
    private func setSpan(_ kind: AgendaSpan, around anchor: Int? = nil) {
        let anchor = anchor ?? anchorDay
        spanKind = kind
        selection = nil
        switch kind {
        case .day:
            agenda.mode = .agenda(span: 1, startOffset: nil)
            agenda.start = anchor
        case .week:
            agenda.mode = .agenda(span: 7, startOffset: nil)
            agenda.start = anchor - (Days.weekday(anchor) + 6) % 7
        case .month:
            let d = Days.date(anchor)
            let first = Days.absolute(year: d.year, month: d.month, day: 1)
            let next = d.month == 12 ? Days.absolute(year: d.year + 1, month: 1, day: 1) : Days.absolute(year: d.year, month: d.month + 1, day: 1)
            agenda.mode = .agenda(span: next - first, startOffset: nil)
            agenda.start = first
        }
    }

    private func move(forward: Bool) {
        selection = nil
        if spanKind == .month, let first = agenda.days.first?.day {
            setSpan(.month, around: forward ? first + 31 : first - 1)
        } else {
            agenda.shift(forward: forward)
        }
    }

    private func goToday() {
        if let spanKind { setSpan(spanKind, around: agenda.today) } else { agenda.showToday() }
        selection = nil
    }

    /// `org-agenda-goto-date`.
    private func goTo(_ day: Int) {
        if let spanKind { setSpan(spanKind, around: day) } else { agenda.start = day }
        selection = nil
    }

    /// Capture on `day`, as `org-agenda-capture`.
    private func capture(on day: Int) {
        commands.capture(on: day)
        NSApp.activate()
        openWindow(id: "capture")
    }

    static func date(_ day: Int) -> Date {
        let d = Days.date(day)
        return Calendar.current.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date()
    }

    static func format(_ day: Int, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = pattern
        return formatter.string(from: date(day))
    }

    static func hhmm(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 100 + (c.minute ?? 0)
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
        case .search(let string, let todoOnly): (todoOnly ? "TODO entries" : "Entries") + " containing \(string)"
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
        spanKind = nil
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
        spanKind = nil
        agenda.start = nil
        switch viewName {
        case Self.match, Self.todoMatch:
            let match = matchText.trimmingCharacters(in: .whitespaces)
            guard !match.isEmpty else { return }
            agenda.mode = .match(match, todoOnly: viewName == Self.todoMatch)
        case Self.search, Self.todoSearch:
            guard matchText.contains(where: { !$0.isWhitespace }) else { return }
            agenda.mode = .search(matchText, todoOnly: viewName == Self.todoSearch)
        default:
            if let view = views.first(where: { $0.name == viewName }) { agenda.mode = view.mode }
        }
    }

    // MARK: - Items

    private func item(_ id: String) -> AgendaItem? { line(id)?.row.item }

    /// Return and double click: the entry in the main window, or the event in Calendar.
    private func open(_ line: Line) {
        selection = line.id
        if let event = line.row.event { openEvent(event) } else { jump(line.id) }
    }

    /// Calendar shows an event from its identifier (`AgendaEvent.id` adds `@` and the start).
    private func openEvent(_ event: AgendaEvent) {
        let identifier = event.id.split(separator: "@").dropLast().joined(separator: "@")
        guard !identifier.isEmpty, let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Moves the selection by `step` lines.
    private func step(_ step: Int) {
        let all = lines(groups)
        guard !all.isEmpty else { return }
        let index = selection.flatMap { id in all.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + step, 0), all.count - 1) } ?? (step > 0 ? 0 : all.count - 1)
        selection = all[next].id
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

    /// The entry in the main window; with `focus` false the agenda keeps the keys (SPC).
    private func jump(_ id: String, focus: Bool = true) {
        guard let item = item(id), let path = item.path, let offset = item.markerOffset ?? item.headingOffset else { return }
        commands.jump(path: path, offset: offset)
        if focus { openWindow(id: "main") }
    }

    // MARK: - Commands

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let control = press.modifiers.contains(.control)
        // `C-x` and friends arrive as control characters or as letters with control.
        func isControl(_ letter: String, _ code: String) -> Bool { control && (press.characters == letter || press.characters == code) }
        if let pending = prefix {
            prefix = nil
            if pending == "v" {
                switch press.characters {
                case "d" where isAgenda: setSpan(.day)
                case "w" where isAgenda: setSpan(.week)
                case "m" where isAgenda: setSpan(.month)
                default: message = "v \(press.characters) is undefined"
                }
                if message == "v-" { message = nil }
                return .handled
            }
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
        if isControl("n", "\u{0e}") || (press.key == .downArrow && press.modifiers.isEmpty) {
            step(1)
            return .handled
        }
        if isControl("p", "\u{10}") || (press.key == .upArrow && press.modifiers.isEmpty) {
            step(-1)
            return .handled
        }
        if press.key == .return || press.key == .tab, let selection, let line = line(selection) {
            open(line)
            return .handled
        }
        if press.key == .space, let selection {
            jump(selection, focus: false)
            return .handled
        }
        if press.modifiers == .shift, press.key == .rightArrow || press.key == .leftArrow {
            run(ShiftTimestampDay(later: press.key == .rightArrow), atMarker: true)
            return .handled
        }
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch press.characters {
        case "n": step(1)
        case "p": step(-1)
        case "f" where isAgenda: move(forward: true)
        case "b" where isAgenda: move(forward: false)
        case "." where isAgenda: goToday()
        case "j" where isAgenda:
            pickedDate = Self.date(anchorDay)
            showingDatePicker = true
        case "v" where isAgenda:
            prefix = "v"
            message = "v-"
        case "d" where isAgenda: setSpan(.day)
        case "w" where isAgenda: setSpan(.week)
        case "k" where isAgenda: capture(on: anchorDay)
        case "s":
            commands.run("app.save-all")
            message = "Saved"
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
        case ",": run(SetPriority())
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

/// One agenda line: the time or status over an icon, the category above the title, progress
/// and tags after it, and the TODO keyword and priority at the end.
struct AgendaRowView: View {
    let row: AgendaRow
    /// The agenda day the row is on, for habit graphs.
    var day: Int
    var showsGutter = true
    var selected = false
    var hovered = false
    /// Marked for a bulk action.
    var marked = false
    @Environment(\.orgTheme) private var theme

    static let gutterWidth: CGFloat = 92

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsGutter { gutter }
            VStack(alignment: .leading, spacing: 2) {
                if !row.category.isEmpty { categoryLine }
                titleLine
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let habit = row.item?.habit {
                HabitGraph(cells: habit.graph(today: day), theme: theme)
            }
            if let todo = row.todo {
                let color = theme.dynamic(row.isDone ? .systemGreen : .systemRed) { [theme, row] in theme.todoColor(todo, isDone: row.isDone, dark: $0) }
                Text(todo)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .fixedSize()
            }
            priorityBadge
                .frame(width: 18)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        // `org-agenda-dim-blocked-tasks`.
        .opacity(row.isBlocked ? 0.5 : 1)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? theme.color("selection") ?? Color.accentColor.opacity(0.2) : hovered ? Color.primary.opacity(0.05) : .clear)
                .padding(.horizontal, 6)
        }
        .overlay(alignment: .leading) {
            if marked {
                Capsule().fill(theme.color("agenda-today") ?? .accentColor).frame(width: 3).padding(.vertical, 8).padding(.leading, 8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        theme.dynamic(.secondaryLabelColor) { [theme, row] in theme.statusColor(row.status, dark: $0) }
    }

    private var gutter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.gutter)
                .font(.system(size: 12, weight: row.status == .overdue || row.status == .dueSoon ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: row.icon == .event ? 8 : 10, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(height: 12)
            }
        }
        .frame(width: Self.gutterWidth, alignment: .leading)
    }

    /// Overdue entries show a warning, done ones a check, as the status says first.
    private var symbol: String? {
        guard let icon = row.icon else { return nil }
        if row.status == .overdue { return "exclamationmark.circle.fill" }
        if row.status == .done { return "checkmark.circle.fill" }
        switch icon {
        case .scheduled: return "calendar"
        case .deadline: return "flag.fill"
        case .habit: return "repeat"
        case .event: return "circle.fill"
        case .timestamp: return row.start == nil ? "calendar" : "clock"
        }
    }

    private var iconColor: Color {
        if let event = row.event { return theme.dynamic(.systemPurple) { [theme] in theme.eventColor(event, dark: $0) } }
        return row.status == .normal ? Color.secondary.opacity(0.8) : statusColor
    }

    private var categoryLine: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(row.event.map { event in theme.dynamic(.systemPurple) { [theme] in theme.eventColor(event, dark: $0) } }
                    ?? theme.dynamic { [theme, row] in theme.categoryColor(row.category, dark: $0) })
                .frame(width: 6, height: 6)
            Text(row.category + (row.event?.location.map { " · " + $0 } ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(theme.color("agenda-category") ?? .secondary)
                .lineLimit(1)
        }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(row.title.isEmpty ? " " : row.title)
                .font(.system(size: 13))
                .strikethrough(row.isDone)
                .foregroundStyle(row.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.color("foreground") ?? .primary))
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach([row.progress, row.detail].compactMap { $0 }, id: \.self) { progress in
                Text(progress)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .fixedSize()
            }
            ForEach(row.tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.color("tags") ?? .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().strokeBorder((theme.color("tags") ?? .secondary).opacity(0.35), lineWidth: 0.5))
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var priorityBadge: some View {
        if let priority = row.priority {
            let color = theme.dynamic(.systemOrange) { [theme] in theme.priorityColor(priority, dark: $0) }
            Text(priority)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(color.opacity(0.14)))
                .overlay(Circle().strokeBorder(color.opacity(0.6), lineWidth: 1))
                .help("Priority \(priority)")
        } else {
            Color.clear.frame(width: 18, height: 18)
        }
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
