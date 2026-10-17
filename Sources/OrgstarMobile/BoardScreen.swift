#if os(iOS)
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI

/// The agenda files' entries as a list, or as a kanban board by TODO keyword, as on the Mac.
/// Dragging a card to another column, or Move To in its menu, sets its keyword.
struct BoardScreen: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    let done: () -> Void
    @Environment(MobileModel.self) private var model
    @State private var agenda: AgendaModel
    @State private var entries: [BoardEntry] = []
    @State private var keywords: [String] = []
    @State private var message: String?
    @State private var tick = 0
    @State private var prompt: EditorScreen.PromptRequest?
    @State private var matchText = ""
    @AppStorage("boardKanban") private var kanban = false
    @AppStorage("boardMatch") private var match = ""

    init(workspace: WorkspaceModel, session: DocumentSession, done: @escaping () -> Void) {
        self.workspace = workspace
        self.session = session
        self.done = done
        _agenda = State(initialValue: AgendaModel(workspace: workspace))
    }

    private var theme: MobileTheme { MobileTheme(model.theme) }

    private struct RefreshKey: Hashable {
        var match: String
        var files: Int
        var changed: Int?
        var edits: Int
        var tick: Int
        var settings: Int
    }

    /// Entries by keyword order, then title.
    private var sorted: [BoardEntry] {
        entries.enumerated().sorted { a, b in
            let ka = a.element.todo.flatMap { keywords.firstIndex(of: $0) } ?? Int.max
            let kb = b.element.todo.flatMap { keywords.firstIndex(of: $0) } ?? Int.max
            if ka != kb { return ka < kb }
            if a.element.title != b.element.title { return a.element.title.localizedStandardCompare(b.element.title) == .orderedAscending }
            return a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Match: +work/!TODO", text: $matchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { match = matchText }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)
                if kanban { board } else { list }
            }
            .safeAreaInset(edge: .bottom) {
                if let message {
                    Text(message).font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                        .onTapGesture { self.message = nil }
                }
            }
            .navigationTitle(kanban ? "Kanban" : "Entries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: done) }
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $kanban) {
                        Label("List", systemImage: "list.bullet").tag(false)
                        Label("Kanban", systemImage: "rectangle.split.3x1").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
            .sheet(item: $prompt) { request in
                PromptSheet(prompt: request.prompt) { answer in
                    prompt = nil
                    request.reply(answer)
                }
            }
        }
        .onAppear { matchText = match }
        .task(id: RefreshKey(match: match, files: workspace.files.count, changed: workspace.changedFile?.version, edits: session.editVersion,
                             tick: tick, settings: model.settingsVersion)) {
            agenda.includeSubfolders = OrgPreferences.agendaSubfolders()
            agenda.excludeArchives = OrgPreferences.agendaExcludeArchives()
            agenda.agendaFiles = OrgPreferences.agendaFiles()
            let result = await agenda.board(open: session.openTexts, match: match)
            entries = result.entries
            keywords = result.keywords
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if entries.isEmpty { Text("No entries").foregroundStyle(.secondary) }
            ForEach(sorted) { entry in
                Button { open(entry) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let todo = entry.todo {
                            Text(todo).font(.caption.weight(.bold)).foregroundStyle(keywordColor(todo, done: entry.isDone))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text((entry.priority.map { "[#\($0)] " } ?? "") + entry.title).foregroundStyle(.primary)
                            details(entry)
                        }
                    }
                }
                .tint(.primary)
                .contextMenu { menu(entry) }
            }
        }
    }

    // MARK: - Kanban

    private var board: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(keywords, id: \.self) { keyword in column(keyword) }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func column(_ keyword: String) -> some View {
        let cards = entries.filter { $0.todo == keyword }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(keyword).font(.headline).foregroundStyle(keywordColor(keyword, done: cards.first?.isDone ?? false))
                Text("\(cards.count)").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cards) { entry in
                        card(entry)
                            .onTapGesture { open(entry) }
                            .draggable(entry.id)
                            .contextMenu { menu(entry) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { open(entry) }
                            .accessibilityActions {
                                ForEach(keywords.filter { $0 != keyword }, id: \.self) { other in
                                    Button("Move to \(other)") { setTodo(entry, other) }
                                }
                            }
                    }
                }
            }
        }
        .frame(width: 260, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
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
            details(entry)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.systemBackground)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func details(_ entry: BoardEntry) -> some View {
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

    @ViewBuilder
    private func menu(_ entry: BoardEntry) -> some View {
        Menu("Move To", systemImage: "arrow.right.circle") {
            ForEach(keywords.filter { $0 != entry.todo }, id: \.self) { keyword in Button(keyword) { setTodo(entry, keyword) } }
            if entry.todo != nil {
                Divider()
                Button(String(localized: "none.state", defaultValue: "None", comment: "No TODO state")) { setTodo(entry, nil) }
            }
        }
        Button("Set Property…", systemImage: "list.bullet.rectangle") { askProperty(entry) }
        Button("Open", systemImage: "doc.text") { open(entry) }
    }

    private func keywordColor(_ keyword: String, done: Bool) -> Color {
        theme.keywordColor(keyword, done: done).map(Color.init(uiColor:)) ?? (done ? .green : .red)
    }

    // MARK: - Editing

    private func perform(_ command: any OrgCommand, on entry: BoardEntry, answers: [String: String] = [:]) {
        switch session.perform(command, path: entry.path, at: entry.headingOffset, expect: (entry.headingOffset, entry.headingLine), answers: answers) {
        case .failed(let text): message = text
        case .prompt(let request):
            // A state note, or what else the change asks.
            prompt = EditorScreen.PromptRequest(prompt: request) { answer in
                guard let answer else { return }
                perform(command, on: entry, answers: answers.merging([request.key: answer]) { $1 })
            }
        case .external(let request): message = MobileEditor.unavailable(request, title: command.title)
        case .commit: message = nil
        }
        tick += 1
    }

    private func setTodo(_ entry: BoardEntry, _ keyword: String?) {
        perform(SetTodo(keyword: keyword), on: entry)
    }

    private func askProperty(_ entry: BoardEntry) {
        prompt = EditorScreen.PromptRequest(prompt: Prompt(key: "property", message: "Property (NAME value):")) { answer in
            guard let answer, let space = answer.firstIndex(of: " ") else { return }
            let key = String(answer[..<space])
            let value = String(answer[answer.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            perform(SetProperty(key: key, value: value), on: entry)
        }
    }

    private func open(_ entry: BoardEntry) {
        done()
        model.openRequest = .offset(entry.path, entry.headingOffset)
    }
}
#endif
