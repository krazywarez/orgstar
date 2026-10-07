#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import SwiftUI

/// The agenda over the workspace's agenda files: the day/week view, the TODO list, tag and
/// property matches and the views in `views.toml`, with Org's filters and the agenda's
/// actions on each entry.
struct AgendaScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @Bindable var agenda: AgendaModel
    let scheduler: ReminderScheduler
    @State private var message: String?
    @State private var tick = 0
    @State private var views = AgendaViewLoader.builtIn
    @State private var viewName = "Agenda"
    @State private var filter = AgendaFilter()
    @State private var showingFilter = false
    @State private var asking: Asking?
    @State private var prompt: EditorScreen.PromptRequest?
    @State private var refiling: AgendaItem?
    @State private var archiving: AgendaItem?

    /// A match typed for the tag and property view.
    private enum Asking: Identifiable {
        case match
        var id: Int { 0 }
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
    }

    var body: some View {
        List {
            if case .agenda = agenda.mode {
                ForEach(agenda.days, id: \.day) { day in
                    Section {
                        let items = day.items.filter(\.isEntry).filter(filter.keeps)
                        ForEach(items.indices, id: \.self) { i in row(items[i]) }
                    } header: {
                        Text(day.header.split(separator: " ", omittingEmptySubsequences: true).prefix(4).joined(separator: " "))
                            .foregroundStyle(day.isToday ? Color.accentColor : .secondary)
                    }
                }
            } else {
                let items = agenda.list.filter(filter.keeps)
                if items.isEmpty, !agenda.isComputing { Text("No entries").foregroundStyle(.secondary) }
                ForEach(items.indices, id: \.self) { i in row(items[i]) }
            }
            if let reminderStatus {
                Section { } footer: { Text(reminderStatus) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(viewName)
        .overlay {
            if workspace.rootPaths.isEmpty {
                ContentUnavailableView("No folders", systemImage: "folder", description: Text("Add a folder of org files under Folders."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let status = message ?? (filter.isEmpty ? nil : "Filter: " + filter.description) {
                Text(status).font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
                    .onTapGesture { message = nil }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(views) { definition in
                        Button(definition.name) { show(definition) }
                    }
                    Button("Tags and Properties…") { asking = .match }
                    if case .agenda = agenda.mode {
                        Divider()
                        Button("Today", systemImage: "calendar.circle") { agenda.showToday() }
                        Button("Earlier", systemImage: "chevron.left") { agenda.shift(forward: false) }
                        Button("Later", systemImage: "chevron.right") { agenda.shift(forward: true) }
                    }
                } label: {
                    Label("Views", systemImage: "calendar")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Filter", systemImage: filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                    showingFilter = true
                }
            }
        }
        .sheet(isPresented: $showingFilter) {
            FilterSheet(filter: $filter, items: shownItems)
        }
        .sheet(item: $asking) { _ in
            PromptSheet(prompt: Prompt(key: "match", message: "Match: tags and properties, as +work-home or TODO=\"WAIT\"")) { answer in
                asking = nil
                guard let answer, !answer.isEmpty else { return }
                agenda.mode = .match(answer, todoOnly: false)
                viewName = answer
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
        .task(id: Key(files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion, tick: tick,
                      mode: agenda.mode, start: agenda.start, span: agenda.span, startOffset: agenda.startOffset,
                      subfolders: agenda.includeSubfolders)) {
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

    // MARK: - Rows

    private func row(_ item: AgendaItem) -> some View {
        Group {
            if let path = item.path, let offset = item.headingOffset {
                NavigationLink(value: ReaderRoute.offset(path, offset)) { entry(item) }
            } else {
                entry(item)
            }
        }
        .swipeActions(edge: .trailing) {
            if item.todo != nil, !item.isDone, doneKeyword(for: item) != nil {
                Button("Done", systemImage: "checkmark") { markDone(item) }.tint(.green)
            }
        }
        .contextMenu {
            if item.path != nil {
                Button("TODO State…", systemImage: "checkmark.circle") { run("org.todo.cycle", on: item) }
                Button("Schedule…", systemImage: "calendar") { run("org.schedule", on: item) }
                Button("Deadline…", systemImage: "calendar.badge.exclamationmark") { run("org.deadline", on: item) }
                Button("Tags…", systemImage: "tag") { run("org.tags.set", on: item) }
                Button("Priority…", systemImage: "exclamationmark.circle") { run("org.priority.set", on: item) }
                Divider()
                Button("Refile…", systemImage: "arrow.turn.down.right") { refiling = item }
                Button("Archive…", systemImage: "archivebox") { archiving = item }
            }
        }
    }

    private func entry(_ item: AgendaItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let time = item.time.firstMatch(of: /[0-9]{1,2}:[0-9]{2}(-[0-9]{1,2}:[0-9]{2})?/) {
                    Text(time.output.0).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(item.text).strikethrough(item.isDone)
            }
            HStack(spacing: 6) {
                Text(item.category)
                let extra = item.extra.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !extra.isEmpty { Text(extra) }
                if !item.tags.isEmpty { Text(item.tags.map { ":" + $0 }.joined() + ":") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

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
        case .external:
            message = "\(command.title) needs Emacs, which runs on the Mac."
        case .commit:
            message = nil
        }
        tick += 1
    }

    /// The first done keyword of the item's TODO sequence.
    private func doneKeyword(for item: AgendaItem) -> String? {
        guard let todo = item.todo, let path = item.path else { return nil }
        let text = session.openTexts[path] ?? (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let settings = OrgParser.parse(text).settings
        return settings.todoSequences.first { ($0.active + $0.done).contains { $0.name == todo } }?.done.first?.name
    }

    private func markDone(_ item: AgendaItem) {
        guard let keyword = doneKeyword(for: item) else { return }
        run(SetTodo(keyword: keyword), on: item)
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
}

extension AgendaItem: Identifiable {
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
