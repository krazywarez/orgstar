import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI
import UniformTypeIdentifiers

/// Entries of the agenda files as a sortable table with property columns, or as a kanban
/// board by TODO keyword. Dragging a card to a column sets its keyword; edits go through the
/// open buffer or the file.
struct BoardView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let commands: AppCommands
    @State private var agenda: AgendaModel
    @State private var entries: [BoardEntry] = []
    @State private var keywords: [String] = []
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\BoardRow.todoOrder), KeyPathComparator(\BoardRow.title)]
    @State private var message: String?
    @State private var tick = 0
    @AppStorage("boardKanban") private var kanban = false
    @AppStorage("boardMatch") private var match = ""
    @AppStorage("boardColumns") private var columnText = "EFFORT"
    @AppStorage("agendaSubfolders") private var includeSubfolders = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.orgTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    init(workspace: WorkspaceModel, session: DocumentSession, commands: AppCommands) {
        self.workspace = workspace
        self.session = session
        self.commands = commands
        _agenda = State(initialValue: AgendaModel(workspace: workspace))
    }

    private var propertyColumns: [String] {
        columnText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }

    private var rows: [BoardRow] {
        entries.map { BoardRow(entry: $0, todoOrder: $0.todo.flatMap { keywords.firstIndex(of: $0) } ?? Int.max) }.sorted(using: sortOrder)
    }

    private struct RefreshKey: Hashable {
        var match: String
        var subfolders: Bool
        var files: Int
        var changed: Int?
        var edits: Int
        var path: String?
        var tick: Int
    }

    var body: some View {
        Group {
            if kanban { board } else { table }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message {
                Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("View", selection: $kanban) {
                    Label("Table", systemImage: "tablecells").tag(false)
                    Label("Kanban", systemImage: "rectangle.split.3x1").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("Match: +work/!TODO", text: $match)
                    .frame(minWidth: 200)
                if !kanban {
                    TextField("Property columns", text: $columnText)
                        .frame(minWidth: 140)
                        .help("Property names to show as columns, separated by commas")
                }
            }
        }
        .navigationTitle(kanban ? "Kanban" : "Entries")
        .task(id: RefreshKey(match: match, subfolders: includeSubfolders, files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion, path: session.path, tick: tick)) {
            agenda.includeSubfolders = includeSubfolders
            agenda.agendaFiles = OrgPreferences.agendaFiles()
            let open = session.openTexts
            let result = await agenda.board(open: open, match: match)
            entries = result.entries
            keywords = result.keywords
        }
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("TODO", value: \.todoOrder) { row in
                Text(row.entry.todo ?? "").foregroundStyle(theme.keywordColor(row.entry.todo ?? "", done: row.entry.isDone)).bold()
            }
            .width(min: 50, ideal: 60, max: 90)
            TableColumn("P", value: \.priority) { row in Text(row.priority) }
                .width(min: 20, ideal: 24, max: 40)
            TableColumn("Title", value: \.title) { row in Text(row.title).lineLimit(1) }
                .width(min: 160, ideal: 320)
            TableColumn("Tags", value: \.tags) { row in Text(row.tags).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 60, ideal: 120)
            TableColumn("Scheduled", value: \.scheduled) { row in Text(row.scheduled).monospacedDigit() }
                .width(min: 80, ideal: 110)
            TableColumn("Deadline", value: \.deadline) { row in Text(row.deadline).monospacedDigit() }
                .width(min: 80, ideal: 110)
            TableColumnForEach(propertyColumns, id: \.self) { key in
                TableColumn(key.capitalized) { (row: BoardRow) in Text(row.entry.properties[key] ?? "") }
                    .width(min: 50, ideal: 80)
            }
            TableColumn("File", value: \.file) { row in Text(row.file).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 60, ideal: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) {
                Menu("Set TODO") {
                    ForEach(keywords, id: \.self) { keyword in Button(keyword) { setTodo(entry, keyword) } }
                    Divider()
                    Button("None") { setTodo(entry, nil) }
                }
                Button("Set Property…") { askProperty(entry) }
                Button("Open") { jump(entry) }
            }
        } primaryAction: { ids in
            if let entry = entries.first(where: { ids.contains($0.id) }) { jump(entry) }
        }
    }

    // MARK: - Kanban

    private var board: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(keywords, id: \.self) { keyword in
                    column(keyword)
                }
            }
            .padding(12)
        }
        .background(theme.color("agenda-background", in: colorScheme) ?? .clear)
    }

    private func column(_ keyword: String) -> some View {
        let cards = entries.filter { $0.todo == keyword }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(keyword).font(.headline).foregroundStyle(theme.keywordColor(keyword, done: cards.first?.isDone ?? false))
                Text("\(cards.count)").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cards) { entry in
                        card(entry)
                            .draggable(entry.id)
                            .onTapGesture(count: 2) { jump(entry) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { jump(entry) }
                            .accessibilityActions {
                                // Dragging between columns, for VoiceOver.
                                ForEach(keywords.filter { $0 != keyword }, id: \.self) { other in
                                    Button("Move to \(other)") { setTodo(entry, other) }
                                }
                            }
                    }
                }
            }
        }
        .frame(width: 240, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .dropDestination(for: String.self) { ids, _ in
            for id in ids {
                if let entry = entries.first(where: { $0.id == id }), entry.todo != keyword { setTodo(entry, keyword) }
            }
            return true
        }
    }

    private func card(_ entry: BoardEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((entry.priority.map { "[#\($0)] " } ?? "") + entry.title).lineLimit(3)
            HStack(spacing: 6) {
                Text(entry.category).font(.caption).foregroundStyle(.secondary)
                if !entry.tags.isEmpty {
                    Text(entry.tags.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let deadline = entry.deadline {
                Text("Deadline \(deadline)").font(.caption).foregroundStyle(.red)
            } else if let scheduled = entry.scheduled {
                Text("Scheduled \(scheduled)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Editing

    private func perform(_ command: any OrgCommand, on entry: BoardEntry, answers: [String: String] = [:]) {
        switch session.perform(command, path: entry.path, at: entry.headingOffset, expect: (entry.headingOffset, entry.headingLine), answers: answers) {
        case .failed(let text): message = text
        case .prompt(let prompt):
            // A state note: asked in the main window's echo area.
            commands.ask(prompt) { answer in
                guard let answer else { return }
                perform(command, on: entry, answers: answers.merging([prompt.key: answer]) { $1 })
            }
            openWindow(id: "main")
        default: message = nil
        }
        tick += 1
    }

    private func setTodo(_ entry: BoardEntry, _ keyword: String?) {
        perform(SetTodo(keyword: keyword), on: entry)
    }

    private func askProperty(_ entry: BoardEntry) {
        commands.ask(Prompt(key: "property", message: "Property (NAME value):")) { answer in
            guard let answer, let space = answer.firstIndex(of: " ") else { return }
            let key = String(answer[..<space])
            let value = String(answer[answer.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            perform(SetProperty(key: key, value: value), on: entry)
        }
        openWindow(id: "main")
    }

    private func jump(_ entry: BoardEntry) {
        commands.jump(path: entry.path, offset: entry.headingOffset)
        openWindow(id: "main")
    }
}

/// A table row with sortable values.
struct BoardRow: Identifiable {
    let entry: BoardEntry
    let todoOrder: Int
    var id: String { entry.id }
    var title: String { entry.title }
    var priority: String { entry.priority ?? "" }
    var tags: String { entry.tags.joined(separator: " ") }
    var scheduled: String { entry.scheduled ?? "" }
    var deadline: String { entry.deadline ?? "" }
    var file: String { (entry.path as NSString).lastPathComponent }
}
