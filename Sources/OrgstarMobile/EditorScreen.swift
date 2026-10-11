#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    /// The session's options with `buffer-file-name` and the agenda files, for clock tables.
    private var editorOptions: EditingOptions {
        var options = session.options
        options.filePath = path
        options.agendaFiles = workspace.agendaFilePaths()
        return options
    }

    struct PromptRequest: Identifiable {
        let id = UUID()
        let prompt: Prompt
        let reply: (String?) -> Void
    }

    /// One sheet at a time: two presenters on this screen interfere.
    /// `org-table-import`'s file picker is up.
    @State private var importingTable = false
    /// The table at the caret, for `org-table-export`'s save dialog.
    @State private var exportedTable: TableFile?

    enum Sheet: Identifiable {
        case palette, conflict, syncCopies, recovery
        /// `app.refile`, `app.refile.copy` or `app.refile.goto`.
        case refile(String)
        case block(BlockEdit)
        case columns(ColumnView.View)
        case plot(TablePlot.Plot)
        case crypt(CryptRequest)

        var id: String {
            switch self {
            case .palette: "palette"
            case .refile(let command): command
            case .conflict: "conflict"
            case .syncCopies: "syncCopies"
            case .recovery: "recovery"
            case .block(let edit): "block \(edit.range)"
            case .columns: "columns"
            case .plot: "plot"
            case .crypt(let request): request.id.uuidString
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
        .navigationTitle(session.bufferName(path) + (session.dirtyPaths.contains(path) ? " •" : ""))
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
                    Button("Column View", systemImage: "tablecells") { editor?.run("org.columns") }
                    Button("Column View of File", systemImage: "tablecells.badge.ellipsis") { editor?.run("org.columns.global") }
                    Menu("Table", systemImage: "tablecells") {
                        Button("Import Table from File…", systemImage: "square.and.arrow.down") { importingTable = true }
                        Button("Export Table as CSV…", systemImage: "square.and.arrow.up") { exportTable(csv: true) }
                        Button("Export Table as TSV…", systemImage: "square.and.arrow.up") { exportTable(csv: false) }
                        Button("Plot Table", systemImage: "chart.xyaxis.line") { plotTable() }
                    }
                    Toggle(isOn: Binding(get: { model.showMarkup }, set: { model.showMarkup = $0 })) {
                        Label("Show Markup", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    RecentClockMenu(clock: clock) { editor?.run($0) }
                    Menu("Encryption", systemImage: "lock") {
                        Button("Encrypt Entry…", systemImage: "lock") { crypt("app.crypt.encrypt-entry") }
                        Button("Decrypt Entry…", systemImage: "lock.open") { crypt("app.crypt.open-entry") }
                        Button("Decrypt Entry in File…", systemImage: "lock.open.trianglebadge.exclamationmark") { crypt("app.crypt.decrypt-entry") }
                        Button("Encrypt Tagged Entries…", systemImage: "lock.rectangle.stack") { crypt("app.crypt.encrypt-entries") }
                        Button("Forget Encryption Passphrase", systemImage: "key.slash") { crypt("app.crypt.forget-passphrase") }
                    }
                    if let text = session.document?.text, session.path == path { ExportMenu(path: path, text: text) { message = $0 } }
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
            case .refile(let command):
                RefileSheet(targets: workspace.refileTargets(openPath: session.path, document: session.document),
                            create: command == "app.refile.goto" || OrgPreferences.refileSettings().creating == .no ? nil : { parent, child in
                    self.sheet = nil
                    switch session.createRefileChild(under: parent, title: child) {
                    case .success(let target):
                        guard let path = session.path, let editor else { return }
                        message = session.refile(to: target, from: (path, editor.editContext().caret), keep: command == "app.refile.copy")
                    case .failure(.message(let text)): message = text
                    }
                }) { target in
                    self.sheet = nil
                    guard let target else { return }
                    if command == "app.refile.goto" {
                        model.openRequest = .offset(target.path, target.start ?? Int.max)
                    } else {
                        refile(to: target, keep: command == "app.refile.copy")
                    }
                }
            case .block(let edit):
                BlockEditSheet(edit: edit, theme: MobileTheme(model.theme)) { content in
                    self.sheet = nil
                    if let content, let editor { _ = editor.perform(ReplaceBlockLines(edit: edit, content: content)) }
                }
            case .columns(let view):
                ColumnViewScreen(view: view, session: session, path: path) { offset in editor?.reveal(offset) }
            case .plot(let plot):
                PlotScreen(plot: plot)
            case .crypt(let request):
                CryptScreen(request: request, session: session, editor: editor) { message = $0 }
            }
        }
        .fileImporter(isPresented: $importingTable, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            importTable(result)
        }
        .fileExporter(isPresented: Binding(get: { exportedTable != nil }, set: { if !$0 { exportedTable = nil } }),
                      document: exportedTable, contentType: exportedTable?.type ?? .commaSeparatedText,
                      defaultFilename: exportedTable?.type == .tabSeparatedText ? "table.tsv" : "table.csv") { result in
            if case .failure(let error) = result { message = error.localizedDescription } else { message = "Export done." }
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
        .onChange(of: model.settingsVersion) {
            editor?.options = editorOptions
            editor?.themeSpec = model.theme
            editor?.keymap = model.keymap
            editor?.modal = model.modalKeys
        }
        .onChange(of: model.showMarkup) { editor?.showMarkup = model.showMarkup }
        .onDisappear {
            // Typing the reader shows next, and a save, don't wait for the autosave delay.
            if session.dirtyPaths.contains(path) { _ = session.save(path) }
        }
    }

    /// Store Link, Store ID Link and Insert Link, with the links stored while the app runs.
    private func link(_ id: String) {
        guard let editor else { return }
        switch id {
        case "org.link.store":
            message = StoredLink.add(Links.store(in: editor.editContext(), path: Links.abbreviate(path, home: NSHomeDirectory())), to: &model.storedLinks)
        case "org.id.store-link":
            if case .commit = editor.perform(CreateID()),
               let link = Links.storeID(in: editor.editContext(), fileName: (path as NSString).lastPathComponent) {
                message = StoredLink.add(link, to: &model.storedLinks)
            }
        default:
            _ = editor.perform(InsertLink(stored: model.storedLinks, file: path))
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
            let editor = MobileEditor(
                document: document, editable: document.isEditable, options: editorOptions, theme: model.theme,
                showMarkup: model.showMarkup, baseDirectory: URL(fileURLWithPath: path).deletingLastPathComponent()
            )
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
            editor.onColumnView = { view in sheet = .columns(view) }
            editor.onTangle = { scope in message = session.tangle(scope) }
            editor.onBabel = { job in run(job) }
            editor.onRefreshSetup = { session.refreshSetup() }
            editor.onAgenda = { start, count in model.agendaRequest = .init(start: start, count: count) }
            editor.keymap = model.keymap
            editor.modal = model.modalKeys
            editor.onAppCommand = { id in
                if id == "app.save" {
                    _ = session.save(path)
                } else if ["app.refile", "app.refile.copy", "app.refile.goto"].contains(id) {
                    sheet = .refile(id)
                } else if id == "app.table-import" {
                    importingTable = true
                } else if id == "app.table-export" {
                    exportTable(csv: true)
                } else if id == "app.plot" {
                    plotTable()
                } else if id.hasPrefix("app.crypt.") {
                    crypt(id)
                } else if id == "app.toggle-markup" {
                    model.showMarkup.toggle()
                } else if MobileEditor.linkCommands.contains(id) {
                    link(id)
                } else if !MobileClock.run(id, model: model, workspace: workspace, show: { message = $0 }) {
                    message = "Not available on iOS yet"
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

extension EditorScreen {
    /// `org-table-import`: a TSV, CSV or space-separated file becomes a table at the caret.
    private func importTable(_ result: Result<URL, Error>) {
        guard case .success(let url) = result, let editor else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return message = "Can't read \(url.lastPathComponent)" }
        _ = editor.perform(ImportTable(contents: contents))
    }

    /// org-crypt's commands at the caret, through the passphrase sheet.
    private func crypt(_ id: String) {
        guard let editor else { return }
        let context = editor.editContext()
        switch id {
        case "app.crypt.forget-passphrase":
            CryptPassphrases.forget(path)
            message = "Passphrase forgotten for \((path as NSString).lastPathComponent)"
        case "app.crypt.encrypt-entries":
            sheet = .crypt(CryptRequest(mode: .encryptAll(tag: OrgPreferences.cryptTag()), path: path, offset: context.caret))
        default:
            guard OrgCrypt.heading(context.text, at: context.caret) != nil else { return message = "Before first headline" }
            let encrypted = OrgCrypt.encryptedRange(context.text, at: context.caret) != nil
            if id == "app.crypt.encrypt-entry" {
                guard !encrypted else { return message = "The entry is encrypted already" }
                sheet = .crypt(CryptRequest(mode: .encrypt, path: path, offset: context.caret))
            } else {
                guard encrypted else { return message = "Not an encrypted entry" }
                sheet = .crypt(CryptRequest(mode: id == "app.crypt.open-entry" ? .open : .decryptInPlace, path: path, offset: context.caret))
            }
        }
    }

    /// `org-plot/gnuplot`, drawn by Swift Charts: written to `file:` when the options name
    /// one, else shown.
    private func plotTable() {
        guard let editor else { return }
        let context = editor.editContext()
        do {
            let plot = try TablePlot.plot(context.text, at: context.caret)
            if let url = PlotOutput.file(plot, directory: URL(fileURLWithPath: path).deletingLastPathComponent()) {
                try PlotOutput.write(plot, to: url)
                message = "Plot written to \(url.lastPathComponent)"
                if editor.showsImages { editor.restyleAll() }
            } else {
                sheet = .plot(plot)
            }
        } catch {
            message = "\(error)"
        }
    }

    /// `org-table-export` of the table at the caret, as CSV or TSV.
    private func exportTable(csv: Bool) {
        guard let editor else { return }
        let context = editor.editContext()
        guard let text = ImportTable.exportText(context.text, at: context.caret, path: csv ? "table.csv" : "table.tsv") else {
            return message = "No table at point"
        }
        exportedTable = TableFile(text: text, type: csv ? .commaSeparatedText : .tabSeparatedText)
    }

    /// `org-refile` of the entry at the caret, to a target worked out again from the files
    /// now, as the agenda's Refile… does.
    func refile(to target: RefileTarget, keep: Bool = false) {
        guard let editor, let path = session.path else { return }
        let caret = editor.editContext().caret
        guard let current = workspace.refileTargets(openPath: path, document: session.document).first(where: { $0.label == target.label }) else {
            message = "Can't find \(target.label) any more."
            return
        }
        message = session.refile(to: current, from: (path, caret), keep: keep)
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
/// A src block's code is highlighted as its language.
struct BlockEditSheet: View {
    let edit: BlockEdit
    let theme: MobileTheme
    let finish: (String?) -> Void
    @State private var text: String?

    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    CodeTextView(text: text, language: edit.language, theme: theme) { self.text = $0 }
                }
            }
            .padding(.horizontal, 8)
            .navigationTitle(edit.title.replacingOccurrences(of: "Editing ", with: "").capitalized(with: nil))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(nil) } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { finish(text ?? edit.content) } }
            }
        }
        .onAppear { text = edit.content }
    }
}

/// A text view for code, restyled with the editor's highlighter after each change.
struct CodeTextView: UIViewRepresentable {
    let text: String
    let language: String?
    let theme: MobileTheme
    let changed: (String) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.backgroundColor = .clear
        view.text = text
        view.delegate = context.coordinator
        context.coordinator.style(view)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextView
        init(_ parent: CodeTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            parent.changed(view.text)
            style(view)
        }

        /// The theme's font and color, then the language's token colors.
        func style(_ view: UITextView) {
            let storage = view.textStorage
            let whole = NSRange(location: 0, length: storage.length)
            let base: [NSAttributedString.Key: Any] = [.font: parent.theme.font, .foregroundColor: parent.theme.foreground]
            storage.beginEditing()
            storage.setAttributes(base, range: whole)
            if let language = parent.language {
                for run in MobileEditor.highlighter.highlights(language: language, code: storage.string) {
                    guard let key = run.category.themeKey, let color = parent.theme.color(key), run.range.upperBound <= storage.length else { continue }
                    storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: run.range.lowerBound, length: run.range.count))
                }
            }
            storage.endEditing()
            view.typingAttributes = base
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
        ("app.clock.goto", "Go to Clocked Entry"), ("app.clock.in-recent", "Clock In to Recent Entry…"),
        ("app.clock.in-last", "Clock In to Last Entry"), ("app.clock.goto-recent", "Go to Recent Clocked Entry…"),
        ("app.clock.default", "Mark as Default Clock Task"), ("app.clock.resolve", "Resolve Open Clocks…"),
        ("app.refile", "Refile…"), ("app.refile.copy", "Copy to Refile Target…"), ("app.refile.goto", "Go to Refile Target…"),
        ("app.toggle-markup", "Show or Hide Markup"),
        ("org.toggle-inline-images", "Show or Hide Inline Images"), ("org.latex-preview", "Show or Hide LaTeX Previews"), ("editor.toggle-truncate-lines", "Truncate or Wrap Long Lines"),
        ("org.table.toggle-column-width", "Shrink or Expand Table Column"), ("org.table.shrink", "Shrink Table Columns with Widths"),
        ("org.table.expand", "Expand Table Columns"),
        ("app.table-import", "Import Table from File…"), ("app.table-export", "Export Table to File…"), ("app.plot", "Plot Table"),
        ("app.crypt.encrypt-entry", "Encrypt Entry…"), ("app.crypt.open-entry", "Decrypt Entry…"), ("app.crypt.decrypt-entry", "Decrypt Entry in File…"),
        ("app.crypt.encrypt-entries", "Encrypt Tagged Entries…"), ("app.crypt.forget-passphrase", "Forget Encryption Passphrase"),
    ]

    /// The commands that apply at the caret and their keys, worked out once when the palette
    /// opens rather than on every keystroke in the search field.
    @State private var applicable: [(id: String, title: String, keys: String?)]?

    var body: some View {
        let shown = (applicable ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        NavigationStack {
            List(shown, id: \.id) { command in
                Button {
                    choose(command.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(command.title).foregroundStyle(.primary)
                        Spacer()
                        if let keys = command.keys {
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
        .onAppear {
            guard applicable == nil else { return }
            let context = editor.editContext()
            applicable = (Self.viewCommands + Commands.everything.map { ($0.id, $0.title) })
                .filter { editor.applies($0.id, in: context) }
                .map { ($0.id, $0.title, editor.keymap.keyLabels(for: $0.id).first) }
        }
    }
}
/// A table as CSV or TSV, for the save dialog.
struct TableFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .tabSeparatedText] }
    let text: String
    let type: UTType

    init(text: String, type: UTType) {
        self.text = text
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
        type = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
/// A plotted table, as the Mac's plot sheet shows it.
struct PlotScreen: View {
    let plot: TablePlot.Plot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlotChart(plot)
                .navigationTitle("Plot")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
/// The passphrase sheet for org-crypt, its new text applied in the editor.
struct CryptScreen: View {
    let request: CryptRequest
    let session: DocumentSession
    let editor: MobileEditor?
    let report: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CryptSheet(request: request, text: { session.document?.text ?? "" }, apply: apply) { message in
                dismiss()
                if let message { report(message) }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func apply(_ new: String) {
        guard let editor else { return }
        let context = editor.editContext()
        let caret = min(context.caret, (new as NSString).length)
        _ = editor.perform(PrecomputedEdit(EditResult(baseRevision: context.revision, edits: TextEdit.between(context.text, new), selection: [caret..<caret])))
    }
}
#endif
