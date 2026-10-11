import AppKit
import OrgApp
import OrgDocument
import OrgCore
import OrgPresentation
import SwiftUI

extension AgendaView {
    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
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
    var title: String {
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
    var anchorDay: Int {
        if let selection, let day = Int(selection.prefix { $0 != ":" }) { return day }
        let days = agenda.days.map(\.day)
        if days.contains(agenda.today) || days.isEmpty { return agenda.today }
        return days[0]
    }

    /// `org-agenda-day-view`, `-week-view`, `-month-view`: the day, the week from Monday
    /// (`org-agenda-start-on-weekday`), or the month around `anchor`.
    func setSpan(_ kind: AgendaSpan, around anchor: Int? = nil) {
        let anchor = anchor ?? anchorDay
        spanKind = kind
        selection = nil
        switch kind {
        case .day:
            agenda.mode = .agenda(span: 1, startOffset: nil)
            agenda.start = anchor
        case .week:
            agenda.mode = .agenda(span: 7, startOffset: nil)
            agenda.start = Days.weekStart(anchor, on: agenda.startOnWeekday)
        case .month:
            let d = Days.date(anchor)
            let first = Days.absolute(year: d.year, month: d.month, day: 1)
            let next = d.month == 12 ? Days.absolute(year: d.year + 1, month: 1, day: 1) : Days.absolute(year: d.year, month: d.month + 1, day: 1)
            agenda.mode = .agenda(span: next - first, startOffset: nil)
            agenda.start = first
        }
    }

    func move(forward: Bool) {
        selection = nil
        if spanKind == .month, let first = agenda.days.first?.day {
            setSpan(.month, around: forward ? first + 31 : first - 1)
        } else {
            agenda.shift(forward: forward)
        }
    }

    func goToday() {
        if let spanKind { setSpan(spanKind, around: agenda.today) } else { agenda.showToday() }
        selection = nil
    }

    /// `org-agenda-goto-date`.
    private func goTo(_ day: Int) {
        if let spanKind { setSpan(spanKind, around: day) } else { agenda.start = day }
        selection = nil
    }

    /// Capture on `day`, as `org-agenda-capture`.
    func capture(on day: Int) {
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
    /// How far ahead notifications are set, as the design asks the agenda to show.
    var reminderStatus: String? {
        guard let scheduler, remindersEnabled else { return nil }
        if !scheduler.isAuthorized { return "Notifications are off for orgstar in System Settings." }
        guard let through = scheduler.scheduledThrough else { return nil }
        return "Reminders are set through " + through.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) + "."
    }

    var listTitle: String {
        if case .agenda = agenda.mode { return "" }
        return agenda.viewSettings[agenda.mode]?.header ?? agenda.mode.title
    }

    func loadViews() {
        let loaded = AgendaViewLoader.load()
        views = loaded.views
        agenda.viewSettings = AgendaViewLoader.settings(loaded.views)
        message = loaded.problems.first
    }

    /// The days of a followed timestamp, in the agenda view.
    func showRequestedDays() {
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

    func applyView() {
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

    // MARK: - Filters

    /// The tags and categories on the view's lines, which filter words are read against.
    var shown: (tags: Set<String>, categories: Set<String>) {
        let shown = isBlocks ? agenda.blocks.flatMap { $0.days.flatMap(\.items) + $0.list } : isAgenda ? agenda.days.flatMap(\.items) : agenda.list
        let items = shown.filter { $0.path != nil }
        return (Set(items.flatMap(\.tags)), Set(items.map(\.category)))
    }

    func askFilter(_ kind: Character) {
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

    func applyFilter() {
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
    func toggleCategoryFilter() {
        if !filter.categories.isEmpty {
            filter.categories = []
        } else if let selection, let item = item(selection) {
            filter.categories = ["+" + item.category]
        } else {
            message = "No entry selected"
        }
    }

    /// The entry in the main window; with `focus` false the agenda keeps the keys (SPC).
    func jump(_ id: String, focus: Bool = true) {
        guard let item = item(id), let path = item.path, let offset = item.markerOffset ?? item.headingOffset else { return }
        commands.jump(path: path, offset: offset)
        if focus { openWindow(id: "main") }
    }
}
