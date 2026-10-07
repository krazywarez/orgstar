#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import SwiftUI
import UIKit

/// Editing a file: the text with Org's folding and styling, a bar of Org keys over the keyboard,
/// and every command in a palette. The editor is the open file's live state, so autosave and
/// merging go through the session as on the Mac.
struct EditorScreen: View {
    let path: String
    let offset: Int?
    let workspace: WorkspaceModel
    let session: DocumentSession
    @State private var editor: MobileEditor?
    @State private var prompt: PromptRequest?
    @State private var message: String?
    @State private var sheet: Sheet?
    @State private var trust = TrustStore()
    /// The command chosen in the palette, run once the palette is gone.
    @State private var chosen: String?
    @Environment(ClockModel.self) private var clock
    @Environment(MobileModel.self) private var model
    @Environment(\.openURL) private var openURL

    struct PromptRequest: Identifiable {
        let id = UUID()
        let prompt: Prompt
        let reply: (String?) -> Void
    }

    /// One sheet at a time: two presenters on this screen interfere.
    enum Sheet: Identifiable {
        case palette, conflict, syncCopies, recovery
        case block(BlockEdit)

        var id: String {
            switch self {
            case .palette: "palette"
            case .conflict: "conflict"
            case .syncCopies: "syncCopies"
            case .recovery: "recovery"
            case .block(let edit): "block \(edit.range)"
            }
        }
    }

    var body: some View {
        Group {
            if let editor {
                EditorTextView(editor: editor, palette: { sheet = .palette })
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView()
            }
        }
        .navigationTitle((path as NSString).lastPathComponent + (session.dirtyPaths.contains(path) ? " •" : ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if session.conflict != nil {
                    Button("Conflict", systemImage: "exclamationmark.triangle") { sheet = .conflict }
                }
                Button("Undo", systemImage: "arrow.uturn.backward") { editor?.run("edit.undo") }
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Commands", systemImage: "command") { sheet = .palette }
                    Button("Clock In", systemImage: "stopwatch") { editor?.run("app.clock.in") }
                    if let text = session.document?.text, session.path == path { ExportMenu(path: path, text: text) }
                    Button("Sync Conflict Copies", systemImage: "doc.on.doc") { sheet = .syncCopies }
                    Button("Recovered Versions", systemImage: "clock.arrow.circlepath") { sheet = .recovery }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let message {
                Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
                    .onTapGesture { self.message = nil }
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(4))
                        if self.message == message { self.message = nil }
                    }
            }
        }
        .sheet(item: $prompt) { request in
            PromptSheet(prompt: request.prompt) { answer in
                prompt = nil
                request.reply(answer)
            }
        }
        .sheet(item: $sheet, onDismiss: {
            // After the sheet has gone, so a command's own prompt can show.
            if let id = chosen {
                chosen = nil
                editor?.run(id)
            }
        }) { sheet in
            switch sheet {
            case .palette: if let editor { CommandPalette(editor: editor) { chosen = $0 } }
            case .conflict: ConflictSheet(session: session)
            case .syncCopies: SyncConflictSheet(session: session) { message = $0 }
            case .recovery: RecoverySheet(session: session) { message = $0 }
            case .block(let edit):
                BlockEditSheet(edit: edit) { content in
                    self.sheet = nil
                    if let content, let editor { _ = editor.perform(ReplaceBlockLines(edit: edit, content: content)) }
                }
            }
        }
        .onChange(of: session.conflict) { _, conflict in
            if conflict != nil, session.path == path { sheet = .conflict }
        }
        .onChange(of: session.lastError) { _, error in
            if let error { message = error; session.lastError = nil }
        }
        .onAppear(perform: start)
        .onChange(of: session.revealRequest?.id) {
            if let offset = session.revealRequest?.offset, session.path == path { editor?.reveal(offset) }
        }
        .onDisappear {
            // Typing the reader shows next, and a save, don't wait for the autosave delay.
            if session.dirtyPaths.contains(path) { _ = session.save(path) }
        }
    }

    /// Runs a block once it's trusted, asking as `org-confirm-babel-evaluate` does.
    private func run(_ job: BabelJob) {
        let go = {
            message = "Running \(job.language) block…"
            session.startBabel(job) { message = $0 }
        }
        if !job.alwaysAsk, trust.isTrusted(path: path, content: job.blockText) { return go() }
        let choices = job.alwaysAsk ? ["yes", "no"] : ["yes", "no", "always"]
        prompt = PromptRequest(prompt: Prompt(key: "confirm", message: "Run this \(job.language) block?", choices: choices)) { answer in
            switch answer {
            case "always":
                trust.trust(path: path, content: job.blockText)
                go()
            case "yes": go()
            default: message = "Not run"
            }
        }
    }

    private func start() {
        if session.path != path { session.open(path) }
        if editor == nil, let document = session.document {
            let editor = MobileEditor(document: document, editable: document.isEditable)
            editor.options = session.options
            editor.knownTags = { [index = workspace.index] in (try? index.tags()) ?? [] }
            editor.onChange = { [weak session] in session?.bufferChanged(path) }
            editor.onMessage = { message = $0 }
            editor.onPrompt = { prompt, reply in self.prompt = PromptRequest(prompt: prompt, reply: reply) }
            editor.onLink = { link in
                switch session.follow(link, workspace: workspace, isText: { _ in false }) {
                case .shown: message = session.path == path ? nil : "Opened \((session.path.map { ($0 as NSString).lastPathComponent }) ?? "")"
                case .openExternally(let url): openURL(url)
                case .message(let text): message = text
                }
            }
            editor.onEditBlock = { edit in sheet = .block(edit) }
            editor.onTangle = { scope in message = session.tangle(scope) }
            editor.onBabel = { job in run(job) }
            editor.onRefreshSetup = { session.refreshSetup() }
            editor.onAgenda = { start, count in model.agendaRequest = .init(start: start, count: count) }
            editor.onAppCommand = { id in
                switch id {
                case "app.clock.in": message = clock.clockIn(session)
                case "app.clock.out": message = clock.clockOut(session)
                case "app.clock.cancel": message = clock.clockOut(session, cancel: true)
                case "app.clock.goto":
                    if let location = clock.location(session) { model.openRequest = .offset(location.path, location.offset) } else { message = "No active clock" }
                default: message = "Not available on iOS yet"
                }
            }
            self.editor = editor
        }
        if let editor { session.attach(editor) }
        if let offset { editor?.reveal(offset) }
        if session.conflict != nil {
            sheet = .conflict
        } else if case let copies = session.syncConflictCopies().count, copies > 0 {
            message = "\(copies) sync conflict \(copies == 1 ? "copy" : "copies") of this file; More › Sync Conflict Copies compares them."
        }
    }
}

/// The editor's text view, with the Org key bar over the keyboard.
struct EditorTextView: UIViewRepresentable {
    let editor: MobileEditor
    let palette: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let bar = UIHostingController(rootView: KeyBar(editor: editor, palette: palette))
        bar.view.frame = CGRect(x: 0, y: 0, width: 400, height: 48)
        bar.view.backgroundColor = .clear
        bar.sizingOptions = []
        editor.textView.inputAccessoryView = bar.view
        context.coordinator.bar = bar
        return editor.textView
    }

    func updateUIView(_ view: UITextView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var bar: UIViewController?
    }
}

/// Org's keys for a touch keyboard: each button does what its key does at the caret, as the
/// Emacs keymap binds it (M-→ demotes a heading, indents an item, moves a table column).
struct KeyBar: View {
    let editor: MobileEditor
    let palette: () -> Void

    private static let keys: [(label: String, symbol: String?, keys: String)] = [
        ("Fold", "arrow.right.to.line", "TAB"),
        ("Overview", "arrow.left.to.line", "S-TAB"),
        ("Promote", "arrow.left", "M-<left>"),
        ("Demote", "arrow.right", "M-<right>"),
        ("Move up", "arrow.up", "M-<up>"),
        ("Move down", "arrow.down", "M-<down>"),
        ("New heading or item", "plus", "M-RET"),
        ("TODO", nil, "C-c C-t"),
        ("Act at point", "checkmark.square", "C-c C-c"),
        ("Schedule", "calendar", "C-c C-s"),
        ("Deadline", "calendar.badge.exclamationmark", "C-c C-d"),
        ("Tags", "tag", "C-c C-q"),
        ("Open link", "link", "C-c C-o"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Commands", systemImage: "command", action: palette)
                ForEach(Self.keys, id: \.keys) { key in
                    Button {
                        editor.run(keys: key.keys)
                    } label: {
                        if let symbol = key.symbol { Label(key.label, systemImage: symbol) } else { Text(key.label).font(.callout.weight(.semibold)) }
                    }
                    .accessibilityLabel(key.label)
                }
                Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { editor.textView.resignFirstResponder() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

/// A command's question: text with choices, a date, or fast selection by keys.
struct PromptSheet: View {
    let prompt: Prompt
    let answer: (String?) -> Void
    @State private var text = ""
    @State private var date = Date()
    @State private var keys: [FastSelection.Input] = []

    var body: some View {
        NavigationStack {
            Form {
                if let fast = prompt.fast {
                    fastSection(fast)
                } else {
                    Section {
                        TextField(prompt.message, text: $text)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { answer(text) }
                    } footer: {
                        if prompt.date != nil { Text("Org's date syntax works too: +2d, fri, 14:00") }
                    }
                    if prompt.date != nil {
                        DatePicker("Date", selection: $date, displayedComponents: [.date])
                            .datePickerStyle(.graphical)
                            .onChange(of: date) { text = Self.stamp(date) }
                    }
                    if !prompt.choices.isEmpty {
                        let matching = prompt.choices.filter { lastPart.isEmpty || $0.localizedCaseInsensitiveContains(lastPart) }
                        Section("Choices") {
                            ForEach(matching.prefix(50), id: \.self) { choice in
                                Button(choice) { choose(choice) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(prompt.message.trimmingCharacters(in: CharacterSet(charactersIn: ": ")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { answer(nil) } }
                if prompt.fast == nil || prompt.fast?.multiple == true {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { answer(prompt.fast == nil ? text : FastSelection.encode(keys)) }
                            .disabled(prompt.requireMatch && prompt.fast == nil && !prompt.choices.isEmpty && !prompt.choices.contains(text))
                    }
                }
            }
        }
        .onAppear {
            text = prompt.initial
            if let day = prompt.date?.defaultDate { date = day }
        }
    }

    /// With a separator (tags), what's typed after the last one.
    private var lastPart: String {
        guard let separator = prompt.completionSeparator else { return text }
        return String(text.split(separator: separator, omittingEmptySubsequences: false).last ?? "")
    }

    private func choose(_ choice: String) {
        guard let separator = prompt.completionSeparator else {
            text = choice
            if prompt.date == nil { answer(choice) }
            return
        }
        var parts = text.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = choice
        text = parts.joined(separator: String(separator)) + String(separator)
    }

    @ViewBuilder
    private func fastSection(_ fast: FastSelection) -> some View {
        let current = fast.multiple ? fast.tags(after: keys) ?? [] : []
        Section {
            ForEach(Array(fast.options.enumerated()), id: \.offset) { _, option in
                Button {
                    if fast.multiple { keys.append(.key(option.key)) } else { answer(String(option.key)) }
                } label: {
                    HStack {
                        Text(option.name).foregroundStyle(.primary)
                        Spacer()
                        if current.contains(option.name) { Image(systemName: "checkmark") }
                        Text(String(option.key)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            if !fast.multiple {
                Button("No keyword") { answer(" ") }
            }
        } footer: {
            if fast.multiple, !fast.inherited.isEmpty { Text("Inherited: :" + fast.inherited.joined(separator: ":") + ":") }
        }
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// `org-edit-special` and `org-table-edit-field`: the text edited apart, put back with Save.
struct BlockEditSheet: View {
    let edit: BlockEdit
    let finish: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .padding(.horizontal, 8)
                .navigationTitle(edit.title.replacingOccurrences(of: "Editing ", with: "").capitalized(with: nil))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(nil) } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { finish(text) } }
                }
        }
        .onAppear {
            text = edit.content
            focused = true
        }
    }
}

/// Every command that applies at the caret, by name.
struct CommandPalette: View {
    let editor: MobileEditor
    /// Called with the chosen command before the palette closes.
    let choose: (String) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private static let viewCommands: [(id: String, title: String)] = [
        ("org.cycle", "Cycle Visibility"), ("org.cycle-global", "Cycle Global Visibility"),
        ("edit.undo", "Undo"), ("edit.redo", "Redo"),
        ("app.clock.in", "Clock In"), ("app.clock.out", "Clock Out"), ("app.clock.cancel", "Cancel Clock"),
        ("app.clock.goto", "Go to Clocked Entry"),
    ]

    var body: some View {
        let context = editor.editContext()
        let all = Self.viewCommands + Commands.everything.map { ($0.id, $0.title) }
        let shown = all.filter { editor.applies($0.id, in: context) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
        NavigationStack {
            List(shown, id: \.id) { command in
                Button {
                    choose(command.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(command.title).foregroundStyle(.primary)
                        Spacer()
                        if let keys = editor.keymap.keyLabels(for: command.id).first {
                            Text(keys).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}
#endif
