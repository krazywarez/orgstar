#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import OrgPresentation
import SwiftUI

/// The agenda over the workspace's agenda files: the day/week view, the TODO list, tag and
/// property matches, text search and the views in `views.toml`, with Org's filters and the
/// agenda's actions on each entry.
struct AgendaScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @Bindable var agenda: AgendaModel
    let scheduler: ReminderScheduler
    @State private var message: String?
    @Environment(ClockModel.self) private var clock
    @Environment(MobileModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var tick = 0
    /// The time the now line shows, kept to the minute while the agenda is open.
    @State private var now = Date()
    @State private var views = AgendaViewLoader.builtIn
    @State private var viewName = "Agenda"
    @State private var filter = AgendaFilter()
    @State private var showingFilter = false
    @State private var asking: Asking?
    @State private var prompt: EditorScreen.PromptRequest?
    @State private var refiling: AgendaItem?
    @State private var archiving: AgendaItem?
    /// The day, week or month shown; nil for `org-agenda-span` and `org-agenda-start-day`.
    @State private var range: SpanRange?
    /// The mode `range` set, to notice when something else changes the view.
    @State private var rangeMode: AgendaMode?
    @State private var jumping = false
    @State private var rescheduling: AgendaRow?
    @AppStorage("agendaOverdueExpanded") private var overdueExpanded = true
    @State private var done = 0
    @State private var moved = 0
    /// `org-agenda-log-mode`: closed entries and clocked time on each day.
    @State private var logMode = false

    /// A match typed for the tag and property view, or a search string.
    private enum Asking: Identifiable {
        case match, search
        var id: Self { self }
    }

    enum SpanRange: String, CaseIterable, Identifiable {
        case day, week, month
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private struct Key: Equatable {
        var files: Int
        var changed: Int?
        var edits: Int
        var tick: Int
        var mode: AgendaMode
        var start: Int?
        var span: Int
        var startOffset: Int
        var subfolders: Bool
        var settings: Int
        var logMode: Bool
    }

    private var isDark: Bool { colorScheme == .dark }
    private var theme: ThemeSpec { model.theme }

    var body: some View {
        List {
            // With no folders the empty state stands alone, not over a column of empty days.
            if workspace.rootPaths.isEmpty {
            } else if case .agenda = agenda.mode {
                let _ = model.settingsVersion
                ForEach(Perf.measure("agenda.groups") { agenda.groups(showAllDates: OrgPreferences.agendaShowAllDates(), keep: filter.keeps) }) { group in
                    Section {
                        day(group)
                    } header: {
                        header(group)
                    }
                }
            } else {
                let rows = agenda.list.filter(filter.keeps).compactMap { AgendaRow(item: $0, day: agenda.today, today: agenda.today) }
                if rows.isEmpty, !agenda.isComputing { Text("No entries").foregroundStyle(.secondary) }
                ForEach(rows) { row($0, day: agenda.today) }
            }
            if let reminderStatus {
                Section { } footer: { Text(reminderStatus) }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        // The now line is shorter than a row.
        .environment(\.defaultMinListRowHeight, 16)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: done)
        .sensoryFeedback(.impact(weight: .light), trigger: moved)
        .onChange(of: agenda.start) {
            // Days a followed timestamp asked for.
            if agenda.start != nil, case .agenda = agenda.mode { viewName = "Agenda" }
        }
        .onChange(of: agenda.mode) {
            if agenda.mode != rangeMode { range = nil }
        }
        .overlay {
            if workspace.rootPaths.isEmpty {
                ContentUnavailableView("No folders", systemImage: "folder", description: Text("Add a folder of org files under Folders."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !workspace.rootPaths.isEmpty { bottomBar }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(views) { definition in
                        Button(definition.name) { show(definition) }
                    }
                    Button("Tags and Properties…") { asking = .match }
                    Button("Search…") { asking = .search }
                } label: {
                    Label("Views", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .sheet(isPresented: $showingFilter) {
            FilterSheet(filter: $filter, items: shownItems)
        }
        .sheet(isPresented: $jumping) {
            DateSheet(title: "Go to Date", action: "Go", initial: date(firstDay)) { picked in
                jumping = false
                if let picked { jump(to: Days.absolute(picked, calendar: .current)) }
            }
        }
        .sheet(item: $rescheduling) { row in
            DateSheet(title: row.icon == .deadline ? "Deadline" : "Schedule", action: "Set", initial: date(row.planningDay ?? agenda.today)) { picked in
                rescheduling = nil
                if let picked, let item = row.item { reschedule(row, item, to: Days.absolute(picked, calendar: .current)) }
            }
        }
        .sheet(item: $asking) { kind in
            if kind == .search {
                PromptSheet(prompt: Prompt(key: "search", message: "Search: a phrase, or +word -word {regexp}; * for headlines, ! for TODO entries")) { answer in
                    asking = nil
                    guard let answer, answer.contains(where: { !$0.isWhitespace }) else { return }
                    agenda.mode = .search(answer, todoOnly: false)
                    viewName = answer
                }
            } else {
                PromptSheet(prompt: Prompt(key: "match", message: "Match: tags and properties, as +work-home or TODO=\"WAIT\"")) { answer in
                    asking = nil
                    guard let answer, !answer.isEmpty else { return }
                    agenda.mode = .match(answer, todoOnly: false)
                    viewName = answer
                }
            }
        }
        .sheet(item: $prompt) { request in
            PromptSheet(prompt: request.prompt) { answer in
                prompt = nil
                request.reply(answer)
            }
        }
        .sheet(item: $refiling) { item in
            RefileSheet(targets: workspace.refileTargets(openPath: session.path, document: session.document)) { target in
                refiling = nil
                if let target { refile(item, to: target) }
            }
        }
        .confirmationDialog("Archive this entry?", isPresented: Binding { archiving != nil } set: { if !$0 { archiving = nil } }, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                if let item = archiving { archive(item) }
                archiving = nil
            }
        } message: {
            Text(archiving?.text ?? "")
        }
        .refreshable {
            await workspace.refresh()
            await agenda.refresh(open: session.openTexts)
        }
        .task {
            let loaded = AgendaViewLoader.load()
            views = loaded.views
            if let problem = loaded.problems.first { message = problem }
        }
        // The now line moves each minute; a new day refreshes the statuses.
        .task {
            while !Task.isCancelled {
                let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
                try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow))
                now = Date()
                if Days.absolute(now, calendar: .current) != agenda.today { tick += 1 }
            }
        }
        // Calendar access is asked for when calendar-events is turned on.
        .task(id: model.settingsVersion) {
            guard OrgPreferences.calendarEvents(), !CalendarEvents.isAuthorized else { return }
            if await model.calendarEvents.requestAccess() { tick += 1 }
        }
        .task(id: Key(files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion, tick: tick,
                      mode: agenda.mode, start: agenda.start, span: agenda.span, startOffset: agenda.startOffset,
                      subfolders: agenda.includeSubfolders, settings: model.settingsVersion, logMode: logMode)) {
            agenda.options.logMode = logMode
            await agenda.refresh(open: session.openTexts)
        }
    }

    private var shownItems: [AgendaItem] {
        if case .agenda = agenda.mode { return agenda.days.flatMap(\.items).filter(\.isEntry) }
        return agenda.list
    }

    private func show(_ definition: AgendaViewDefinition) {
        viewName = definition.name
        agenda.mode = definition.mode
    }

    /// How far ahead notifications are set, as the design asks the agenda to show: iOS keeps
    /// at most 64, and sets no more while the app isn't opened.
    private var reminderStatus: String? {
        guard OrgPreferences.reminders() else { return nil }
        if !scheduler.isAuthorized { return "Notifications are off for Orgstar in Settings." }
        guard let through = scheduler.scheduledThrough else { return nil }
        return "Reminders are set through " + through.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            + ". Open Orgstar to set later ones."
    }

    // MARK: - Days

    private func day(_ group: AgendaDayGroup) -> some View {
        Group {
            if group.isToday, !group.overdue.isEmpty {
                Button {
                    withAnimation { overdueExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(overdueExpanded ? 90 : 0))
                        Text("Overdue").font(.subheadline.weight(.semibold))
                        Text("\(group.overdue.count)").font(.subheadline.monospacedDigit())
                        Spacer()
                    }
                    .foregroundStyle(themed(theme.statusColor(.overdue, dark: isDark), .red))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if overdueExpanded {
                    ForEach(group.overdue) { row($0, day: group.day) }
                }
            }
            if group.isEmpty {
                Text("Nothing scheduled").font(.subheadline).foregroundStyle(.secondary)
            }
            let nowAt = nowIndex(group)
            ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, item in
                if index == nowAt { NowLine(time: now, color: todayColor) }
                row(item, day: group.day)
            }
            if let nowAt, nowAt == group.rows.count { NowLine(time: now, color: todayColor) }
        }
    }

    private func nowIndex(_ group: AgendaDayGroup) -> Int? {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return group.nowIndex(now: (c.hour ?? 0) * 100 + (c.minute ?? 0))
    }

    private var todayColor: Color { themed(theme.color("agenda-today", dark: isDark), .accentColor) }

    private func header(_ group: AgendaDayGroup) -> some View {
        let day = date(group.day).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let color = group.isToday ? todayColor : group.day < agenda.today ? Color.secondary : themed(theme.color("agenda-date", dark: isDark), .primary)
        return HStack(alignment: .firstTextBaseline) {
            Text(group.relativeName(today: agenda.today).map { $0 + " · " + day } ?? day)
                .font(.subheadline.weight(group.isToday ? .bold : .semibold))
                .foregroundStyle(color)
            Spacer()
            Button("Add to \(day)", systemImage: "plus.circle") { model.captureRequest = CaptureRequest(day: group.day) }
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(group.isToday ? todayColor : .secondary)
        }
        .textCase(nil)
    }

    // MARK: - Span

    /// The first day shown, as `Days` numbers it, and how many.
    private var shown: (first: Int, span: Int) {
        var span = agenda.span
        var offset = agenda.startOffset
        if case .agenda(let viewSpan, let viewStart) = agenda.mode {
            span = viewSpan ?? span
            offset = viewStart ?? offset
        }
        return (agenda.start ?? agenda.today + offset, span)
    }

    private var firstDay: Int { shown.first }

    /// The span: `Thu 8 Oct`, `Week of 5 Oct`, `October 2026`, or the days, `5 – 14 Oct`.
    private var title: String {
        guard case .agenda = agenda.mode else { return viewName }
        if viewName != "Agenda", range == nil, agenda.start == nil { return viewName }
        let (first, span) = shown
        let start = date(first)
        if span == 1 { return start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        if span == 7, first == weekStart(first) { return "Week of " + start.formatted(.dateTime.day().month(.abbreviated)) }
        let d = Days.date(first)
        if d.day == 1, span == Days.absolute(year: d.year, month: d.month + 1, day: 1) - first {
            return start.formatted(.dateTime.month(.wide).year())
        }
        return start.formatted(.dateTime.day().month(.abbreviated)) + " – " + date(first + span - 1).formatted(.dateTime.day().month(.abbreviated))
    }

    private func weekStart(_ day: Int) -> Int {
        day - (Days.weekday(day) + 6) % 7
    }

    /// Shows `range` around `day`; nil returns to the configured span.
    private func show(_ range: SpanRange?, around day: Int) {
        self.range = range
        let mode: AgendaMode
        let start: Int?
        switch range {
        case .day:
            (mode, start) = (.agenda(span: 1, startOffset: 0), day)
        case .week:
            (mode, start) = (.agenda(span: 7, startOffset: 0), weekStart(day))
        case .month:
            let d = Days.date(day)
            let first = Days.absolute(year: d.year, month: d.month, day: 1)
            (mode, start) = (.agenda(span: Days.absolute(year: d.year, month: d.month + 1, day: 1) - first, startOffset: 0), first)
        case nil:
            (mode, start) = (.agenda(span: nil, startOffset: nil), day == agenda.today ? nil : day)
        }
        rangeMode = mode
        viewName = "Agenda"
        agenda.mode = mode
        agenda.start = start
    }

    private func step(forward: Bool) {
        if range == nil, case .agenda = agenda.mode {
            agenda.shift(forward: forward)
        } else {
            let (first, span) = shown
            show(range, around: forward ? first + span : first - 1)
        }
    }

    private func jump(to day: Int) {
        show(range, around: day)
    }

    private func goToday() {
        if range == nil { show(nil, around: agenda.today) } else { show(range, around: agenda.today) }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let status = message ?? (filter.isEmpty ? nil : "Filter: " + filter.description) {
                Text(status).font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .onTapGesture { message = nil }
            }
            HStack(spacing: 2) {
                let isAgenda = if case .agenda = agenda.mode { true } else { false }
                if isAgenda {
                    barButton("Earlier", "chevron.left") { step(forward: false) }
                }
                barButton("Filter", filter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill") { showingFilter = true }
                if isAgenda {
                    barButton("Today", "smallcircle.filled.circle") { goToday() }
                    barButton("Go to Date", "calendar") { jumping = true }
                    Menu {
                        Picker("Span", selection: Binding { range } set: { show($0, around: $0 == nil ? agenda.today : firstDay) }) {
                            ForEach(SpanRange.allCases) { Text($0.title).tag(Optional($0)) }
                            Text("\(agenda.span) Days").tag(SpanRange?.none)
                        }
                        Toggle("Log Mode", systemImage: "clock.arrow.circlepath", isOn: $logMode)
                    } label: {
                        Text(range?.title ?? "\(agenda.span) Days")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .lineLimit(1)
                            .frame(minWidth: 52, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Span")
                    barButton("Later", "chevron.right") { step(forward: true) }
                } else {
                    barButton("Agenda", "calendar") { show(nil, around: agenda.today) }
                }
            }
            .padding(.horizontal, 6)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    private func barButton(_ title: String, _ image: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: image, action: action)
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: - Rows

    private func row(_ row: AgendaRow, day: Int) -> some View {
        Group {
            if let item = row.item, let path = item.path, let offset = item.headingOffset ?? item.markerOffset {
                NavigationLink(value: ReaderRoute.offset(path, offset)) { AgendaRowView(row: row, day: day, theme: theme, dark: isDark) }
            } else if let event = row.event {
                // Calendar can't be asked for one event by URL; it opens on the event's day.
                Button {
                    if let url = URL(string: "calshow:\(event.start.timeIntervalSinceReferenceDate)") { openURL(url) }
                } label: {
                    AgendaRowView(row: row, day: day, theme: theme, dark: isDark)
                }
                .tint(.primary)
            } else {
                AgendaRowView(row: row, day: day, theme: theme, dark: isDark)
            }
        }
        .swipeActions(edge: .trailing) {
            if let item = row.item, item.todo != nil, !item.isDone, doneKeyword(for: item) != nil {
                Button("Done", systemImage: "checkmark") { markDone(item) }.tint(.green)
                Button("Next State", systemImage: "arrow.right.circle") { run("org.todo.next", on: item) }.tint(.blue)
            }
        }
        .swipeActions(edge: .leading) {
            if canReschedule(row), let item = row.item {
                Button("Tomorrow", systemImage: "sunrise") { reschedule(row, item, to: agenda.today + 1) }.tint(.orange)
                Button("Next Week", systemImage: "calendar.badge.plus") { reschedule(row, item, to: weekStart(agenda.today) + 7) }.tint(.indigo)
                Button("Pick Date", systemImage: "calendar") { rescheduling = row }.tint(.gray)
            }
        }
        .contextMenu {
            if let item = row.item, item.path != nil {
                Button("TODO State…", systemImage: "checkmark.circle") { run("org.todo.cycle", on: item) }
                if canReschedule(row) {
                    Menu("Reschedule", systemImage: "calendar.badge.clock") {
                        Button("Tomorrow") { reschedule(row, item, to: agenda.today + 1) }
                        Button("Next Week") { reschedule(row, item, to: weekStart(agenda.today) + 7) }
                        Button("Pick Date…") { rescheduling = row }
                    }
                }
                Button("Schedule…", systemImage: "calendar") { run("org.schedule", on: item) }
                Button("Deadline…", systemImage: "calendar.badge.exclamationmark") { run("org.deadline", on: item) }
                Button("Tags…", systemImage: "tag") { run("org.tags.set", on: item) }
                Button("Priority…", systemImage: "exclamationmark.circle") { run("org.priority.set", on: item) }
                Button("Clock In", systemImage: "stopwatch") {
                    if let (path, offset) = locate(item) { clockIn(path, offset) }
                }
                Divider()
                Button("Refile…", systemImage: "arrow.turn.down.right") { refiling = item }
                Button("Archive…", systemImage: "archivebox") { archiving = item }
            }
        }
    }

    // MARK: - Actions

    /// Entries with a heading, not done, that a schedule or deadline can move.
    private func canReschedule(_ row: AgendaRow) -> Bool {
        guard let item = row.item, item.path != nil, item.headingLine != nil, !row.isDone else { return false }
        return item.todo != nil || row.icon == .scheduled || row.icon == .deadline || row.icon == .habit
    }

    /// Moves the row's deadline (on a deadline row) or schedule to `day`, keeping its times,
    /// as `org-agenda-schedule` and `org-agenda-deadline` with a date typed.
    private func reschedule(_ row: AgendaRow, _ item: AgendaItem, to day: Int) {
        let d = Days.date(day)
        var answer = String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
        if let start = row.start {
            answer += String(format: " %02d:%02d", start / 100 % 24, start % 100)
            if let end = row.end { answer += String(format: "-%02d:%02d", end / 100 % 24, end % 100) }
        }
        run(row.icon == .deadline ? "org.deadline" : "org.schedule", on: item, answers: ["date": answer])
        moved += 1
    }

    /// The heading of `item` now, found again by its line in case the file changed.
    private func locate(_ item: AgendaItem) -> (path: String, offset: Int)? {
        guard let path = item.path, let line = item.headingLine, let near = item.headingOffset,
              let offset = session.locateHeading(path: path, line: line, near: near) else {
            message = "The entry changed; the agenda has been refreshed."
            tick += 1
            return nil
        }
        return (path, offset)
    }

    /// `org-agenda-clock-in`: `org-clock-in` at the entry, dangling clocks resolved first.
    private func clockIn(_ path: String, _ offset: Int) {
        let paths = workspace.files.filter { $0.kind == .org }.map(\.path)
        Task {
            let outcome = await clock.clockIn(session, target: .entry(path: path, offset: offset), paths: paths, ask: model.clockPrompts.ask)
            if let jump = outcome.jump { model.openRequest = .offset(jump.path, jump.offset) }
            message = outcome.messages.last { !$0.isEmpty }
        }
    }

    /// Runs a command at the entry's heading, asking what it asks.
    private func run(_ id: String, on item: AgendaItem, answers: [String: String] = [:]) {
        guard let command = Commands.command(id) else { return }
        run(command, on: item, answers: answers)
    }

    private func run(_ command: any OrgCommand, on item: AgendaItem, answers: [String: String] = [:]) {
        guard let (path, offset) = locate(item), let line = item.headingLine else { return }
        switch session.perform(command, path: path, at: offset, expect: (offset, line), answers: answers) {
        case .prompt(let request):
            prompt = EditorScreen.PromptRequest(prompt: request) { answer in
                guard let answer else { return }
                run(command, on: item, answers: answers.merging([request.key: answer]) { $1 })
            }
        case .failed(let text):
            message = text
        case .external(let request):
            message = MobileEditor.unavailable(request, title: command.title)
        case .commit:
            message = nil
        }
        tick += 1
    }

    /// The first done keyword of the item's TODO sequence.
    private func doneKeyword(for item: AgendaItem) -> String? {
        guard let todo = item.todo, let path = item.path, let settings = session.settings(for: path) else { return nil }
        return settings.todoSequences.first { ($0.active + $0.done).contains { $0.name == todo } }?.done.first?.name
    }

    private func markDone(_ item: AgendaItem) {
        guard let keyword = doneKeyword(for: item) else { return }
        run(SetTodo(keyword: keyword), on: item)
        done += 1
    }

    private func refile(_ item: AgendaItem, to target: RefileTarget) {
        guard let (path, offset) = locate(item) else { return }
        // Targets in the entry's own file come from its text now.
        let document = session.openDocuments.first { $0.path == path }?.document
            ?? FileManager.default.contents(atPath: path).map { DocumentState(bytes: [UInt8]($0)) }
        guard let current = workspace.refileTargets(openPath: path, document: document).first(where: { $0.label == target.label }) else {
            message = "Can't find \(target.label) any more."
            return
        }
        message = session.refile(to: current, from: (path, offset))
        tick += 1
    }

    private func archive(_ item: AgendaItem) {
        guard let (path, offset) = locate(item) else { return }
        message = session.archive(from: (path, offset))
        tick += 1
    }

    private func date(_ day: Int) -> Date {
        let d = Days.date(day)
        return Calendar.current.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) ?? Date()
    }

    private func themed(_ color: RGBA?, _ fallback: Color) -> Color { color?.swiftUI ?? fallback }
}

extension RGBA {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// One agenda line: the time or status with an icon in the gutter; the category, title,
/// progress and tags; the TODO keyword and priority on the right.
struct AgendaRowView: View {
    let row: AgendaRow
    /// The day the row is on, for habit graphs.
    let day: Int
    let theme: ThemeSpec
    let dark: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // TODO and match lists have no times or statuses.
            if !row.gutter.isEmpty || row.icon != nil { gutter.frame(width: 82, alignment: .leading) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if !row.category.isEmpty {
                        Circle().fill(categoryColor).frame(width: 7, height: 7)
                        Text(row.category).lineLimit(1).layoutPriority(1)
                    }
                    ForEach([row.progress, row.detail].compactMap { $0 }, id: \.self) { progress in
                        Text(progress).monospacedDigit()
                            .padding(.horizontal, 5)
                            .background(.quaternary.opacity(0.7), in: Capsule())
                    }
                    ForEach(row.tags.prefix(3), id: \.self) { tag in
                        Text(tag).lineLimit(1)
                            .padding(.horizontal, 5)
                            .background(.quaternary.opacity(0.7), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    marks
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(row.title.isEmpty ? " " : row.title)
                    .font(.body)
                    .strikethrough(row.isDone)
                    .foregroundStyle(row.isDone ? .secondary : .primary)
                if let location = row.event?.location {
                    Label(location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let habit = row.item?.habit {
                    HabitStrip(cells: habit.graph(today: day), theme: theme, dark: dark).padding(.top, 3)
                }
            }
        }
        .padding(.vertical, 2)
        // Blocked entries dim, as `org-agenda-dim-blocked-tasks`.
        .opacity(row.isBlocked ? 0.5 : row.isDone ? 0.75 : 1)
    }

    /// The TODO keyword and the priority, on the category's line.
    private var marks: some View {
        HStack(spacing: 5) {
            if let todo = row.todo {
                let color = theme.todoColor(todo, isDone: row.isDone, dark: dark)?.swiftUI ?? .secondary
                Text(todo)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.14), in: Capsule())
            }
            if let priority = row.priority {
                let color = theme.priorityColor(priority, dark: dark)?.swiftUI ?? .orange
                Text(priority)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(color)
                    .frame(width: 18, height: 18)
                    .background(color.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(color, lineWidth: 1.2))
                    .accessibilityLabel("Priority \(priority)")
            }
        }
        .fixedSize()
    }

    private var statusColor: Color {
        theme.statusColor(row.status, dark: dark)?.swiftUI ?? .secondary
    }

    private var categoryColor: Color {
        if let event = row.event { return theme.eventColor(event, dark: dark)?.swiftUI ?? .purple }
        return theme.categoryColor(row.category, dark: dark).swiftUI
    }

    /// The start over the end for timed rows, else the status; the icon under them.
    private var gutter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon ?? "circle").font(.caption2.weight(.semibold)).foregroundStyle(iconColor)
                .frame(width: 14)
                .opacity(icon == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                if row.start != nil {
                    let parts = row.gutter.split(separator: "–", maxSplits: 1)
                    Text(parts.first.map(String.init) ?? row.gutter)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(row.status == .normal ? Color.primary : row.status == .done ? Color.secondary : statusColor)
                    if parts.count > 1 {
                        Text(parts[1]).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else if !row.gutter.isEmpty {
                    Text(row.gutter)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    private var icon: String? {
        switch row.icon {
        case .scheduled: row.status == .overdue ? "exclamationmark.circle.fill" : "calendar"
        case .deadline: row.status == .overdue ? "exclamationmark.triangle.fill" : "flag.fill"
        case .habit: "repeat"
        case .event: "calendar"
        case .timestamp: "clock"
        case nil: nil
        }
    }

    private var iconColor: Color {
        if row.isEvent { return categoryColor }
        return row.status == .normal ? Color(.tertiaryLabel) : statusColor
    }
}

/// The current time between timed rows, as Org's `now - - -` line.
struct NowLine: View {
    let time: Date
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(time.formatted(date: .omitted, time: .shortened))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Circle().fill(color).frame(width: 6, height: 6)
            Rectangle().fill(color).frame(height: 1.5)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .frame(height: 16)
        .accessibilityLabel("Now")
    }
}

/// org-habit's consistency graph, compact: a bar per day, a dot where the habit was done,
/// today outlined.
struct HabitStrip: View {
    let cells: [Habit.Cell]
    let theme: ThemeSpec
    let dark: Bool

    var body: some View {
        HStack(spacing: 1) {
            ForEach(cells, id: \.day) { cell in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(cell.face))
                    .frame(width: 4, height: 12)
                    .overlay {
                        if cell.glyph == "*" { Circle().fill(.white.opacity(0.9)).frame(width: 3, height: 3) }
                    }
                    .overlay {
                        if cell.glyph == "!" { RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.primary, lineWidth: 1) }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Done \(cells.filter { $0.glyph == "*" }.count) of the last \(Habit.precedingDays) days")
    }

    /// Due-state colors, lighter for days to come, as org-habit's faces.
    private func color(_ face: Habit.Face) -> Color {
        func themed(_ key: String, _ fallback: Color) -> Color { theme.color(key, dark: dark)?.swiftUI ?? fallback }
        switch face {
        case .clear: return themed("habit-clear", .blue).opacity(0.7)
        case .clearFuture: return themed("habit-clear", .blue).opacity(0.3)
        case .ready: return themed("habit-ready", .green).opacity(0.8)
        case .readyFuture: return themed("habit-ready", .green).opacity(0.3)
        case .alert: return themed("habit-alert", .yellow).opacity(0.85)
        case .alertFuture: return themed("habit-alert", .yellow).opacity(0.35)
        case .overdue: return themed("habit-overdue", .red).opacity(0.8)
        case .overdueFuture: return themed("habit-overdue", .red).opacity(0.3)
        }
    }
}

/// A date to go to or to schedule on.
struct DateSheet: View {
    let title: String
    let action: String
    let initial: Date
    let done: (Date?) -> Void
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            DatePicker(title, selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(nil) } }
                    ToolbarItem(placement: .confirmationAction) { Button(action) { done(date) } }
                }
            Spacer()
        }
        .presentationDetents([.medium, .large])
        .onAppear { date = initial }
    }
}

extension AgendaItem: @retroactive Identifiable {
    public var id: String { "\(path ?? "")|\(headingOffset ?? -1)|\(kind.rawValue)|\(text)" }

    /// An entry, not a time-grid line.
    var isEntry: Bool { kind != .timeGrid && kind != .currentTime }
}

/// Org's agenda filter: tags and categories of the entries shown, kept or left out, or the
/// filter typed as `/` takes it.
struct FilterSheet: View {
    @Binding var filter: AgendaFilter
    let items: [AgendaItem]
    @State private var typed = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tags = Set(items.flatMap(\.tags)).sorted()
        let categories = Set(items.filter { $0.path != nil }.map(\.category)).sorted()
        NavigationStack {
            Form {
                Section {
                    TextField("+work-home", text: $typed)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(apply)
                } footer: {
                    Text("As Org's / filter: +keep and -drop tags or categories, <0:30 for effort, /regexp/.")
                }
                if !tags.isEmpty {
                    Section("Tags") { ForEach(tags, id: \.self) { term($0, in: \.tags) } }
                }
                if !categories.isEmpty {
                    Section("Categories") { ForEach(categories, id: \.self) { term($0, in: \.categories) } }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Clear") { filter = AgendaFilter(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { apply(); dismiss() } }
            }
        }
        .onAppear { typed = filter.description }
    }

    /// Keep, leave out, or no filter on `name`.
    private func term(_ name: String, in list: WritableKeyPath<AgendaFilter, [String]>) -> some View {
        let state = filter[keyPath: list].contains("+" + name) ? 1 : filter[keyPath: list].contains("-" + name) ? -1 : 0
        return Button {
            var terms = filter[keyPath: list].filter { $0.dropFirst() != Substring(name) }
            if state == 0 { terms.append("+" + name) } else if state == 1 { terms.append("-" + name) }
            filter[keyPath: list] = terms
            typed = filter.description
        } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                Text(state == 1 ? "Keep" : state == -1 ? "Leave out" : "").foregroundStyle(.secondary)
            }
        }
    }

    private func apply() {
        guard typed != filter.description else { return }
        let tags = Set(items.flatMap(\.tags))
        let categories = Set(items.map(\.category))
        filter = AgendaFilter().parse(typed, tags: tags, categories: categories).filter
    }
}

/// Where to refile: the targets `org-refile` offers, searchable.
struct RefileSheet: View {
    let targets: [RefileTarget]
    let choose: (RefileTarget?) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(targets.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }, id: \.self) { target in
                Button(target.label) { choose(target) }.foregroundStyle(.primary)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Refile to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choose(nil) } } }
        }
    }
}
#endif
