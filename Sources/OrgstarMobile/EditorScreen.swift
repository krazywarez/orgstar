#if os(iOS)
import OrgApp
import OrgCore
import OrgDocument
import PhotosUI
import QuickLook
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
    /// The pane this screen shows its file in, from a split; nil makes one for the screen.
    var givenPane: EditorPane? = nil
    /// In a split, the focused pane shows the toolbar and the split the title.
    var inSplit = false
    var isFocused = true
    /// Focus came to this screen's pane.
    var onFocus: () -> Void = {}
    /// The pane commands (`app.split-right` …), which the split runs.
    var onPaneCommand: ((String) -> Void)? = nil
    @State private var editor: MobileEditor?
    /// This screen's view of the editor.
    @State private var textView: UITextView?
    @State private var holder = PaneHolder()
    @Environment(\.horizontalSizeClass) private var sizeClass
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
        options.timer = TimerModel.shared.timer
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
    /// org-attach's file picker is up, for this method.
    @State private var attaching: Attachments.Method?
    @State private var attachingPhotos = false
    @State private var takingPhoto = false
    @State private var photos: [PhotosPickerItem] = []
    /// A file shown in Quick Look.
    @State private var previewed: URL?

    enum Sheet: Identifiable {
        case palette, conflict, syncCopies, recovery
        /// `app.refile`, `app.refile.copy` or `app.refile.goto`.
        case refile(String)
        case block(BlockEdit)
        case columns(ColumnView.View)
        case plot(TablePlot.Plot)
        case crypt(CryptRequest)
        case backlinks
        /// The subtree at this offset, to export.
        case exportSubtree(Int)

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
            case .backlinks: "backlinks"
            case .exportSubtree: "exportSubtree"
            }
        }
    }

    private var pane: EditorPane? { givenPane ?? holder.pane }

    /// The pane commands, as the Mac's View menu has them.
    static let paneCommands = ["app.split-right", "app.split-below", "app.pane-next", "app.pane-close", "app.pane-only"]

    var body: some View {
        Group {
            if let editor, let textView {
                EditorTextView(editor: editor, view: textView, palette: { sheet = .palette })
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                ProgressView()
            }
        }
        .modifier(EditorTitle(title: session.bufferName(path) + (session.dirtyPaths.contains(path) ? " •" : ""), shown: !inSplit))
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !inSplit || isFocused {
            ToolbarItemGroup(placement: .primaryAction) {
                if pane?.conflict != nil {
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
                    Button("Backlinks", systemImage: "arrow.uturn.backward.circle") { sheet = .backlinks }
                    Menu("Daily Notes", systemImage: "calendar") {
                        Button("Today", systemImage: "calendar") { roamActions.run("app.dailies.today") }
                        Button("Yesterday", systemImage: "chevron.backward") { roamActions.run("app.dailies.yesterday") }
                        Button("Tomorrow", systemImage: "chevron.forward") { roamActions.run("app.dailies.tomorrow") }
                        Button("Date…", systemImage: "calendar.badge.clock") { roamActions.run("app.dailies.date") }
                        Button("Capture to Today", systemImage: "square.and.pencil") { roamActions.run("app.dailies.capture-today") }
                        Button("Previous Daily Note", systemImage: "arrow.left") { roamActions.run("app.dailies.previous") }
                        Button("Next Daily Note", systemImage: "arrow.right") { roamActions.run("app.dailies.next") }
                    }
                    Button("Find Node…", systemImage: "point.3.connected.trianglepath.dotted") { roamActions.run("app.node.find") }
                    Button("Insert Node Link…", systemImage: "link") { roamActions.run("app.node.insert") }
                    Menu("Attachments", systemImage: "paperclip") {
                        Button("Attach File…", systemImage: "doc.badge.plus") { attaching = .cp }
                        Button("Attach Photo or Video…", systemImage: "photo.badge.plus") { attachingPhotos = true }
                        if CameraPicker.isAvailable {
                            Button("Take Photo…", systemImage: "camera") { takingPhoto = true }
                        }
                        Button("Attach File from URL…", systemImage: "link.badge.plus") { attachActions.run("app.attach.url") }
                        Button("New Attachment…", systemImage: "square.and.pencil") { attachActions.run("app.attach.new") }
                        Button("Open Attachment…", systemImage: "paperclip") { attachActions.run("app.attach.open") }
                        Button("Show Attachment Folder", systemImage: "folder") { attachActions.run("app.attach.reveal") }
                        Button("Delete Attachment…", systemImage: "trash") { attachActions.run("app.attach.delete") }
                        Button("Delete All Attachments…", systemImage: "trash.slash") { attachActions.run("app.attach.delete-all") }
                        Button("Sync Attachments", systemImage: "arrow.triangle.2.circlepath") { attachActions.run("app.attach.sync") }
                        Button("Set Attachment Folder…", systemImage: "folder.badge.gearshape") { attachActions.run("app.attach.set-directory") }
                        Button("Unset Attachment Folder", systemImage: "folder.badge.minus") { attachActions.run("app.attach.unset-directory") }
                    }
                    Menu("Encryption", systemImage: "lock") {
                        Button("Encrypt Entry…", systemImage: "lock") { crypt("app.crypt.encrypt-entry") }
                        Button("Decrypt Entry…", systemImage: "lock.open") { crypt("app.crypt.open-entry") }
                        Button("Decrypt Entry in File…", systemImage: "lock.open.trianglebadge.exclamationmark") { crypt("app.crypt.decrypt-entry") }
                        Button("Encrypt Tagged Entries…", systemImage: "lock.rectangle.stack") { crypt("app.crypt.encrypt-entries") }
                        Button("Forget Encryption Passphrase", systemImage: "key.slash") { crypt("app.crypt.forget-passphrase") }
                    }
                    if let text = session.document(of: path)?.text {
                        ExportMenu(path: path, text: text, report: { message = $0 }, exportSubtree: exportSubtree)
                    }
                    Button("Sync Conflict Copies", systemImage: "doc.on.doc") { sheet = .syncCopies }
                    Button("Recovered Versions", systemImage: "clock.arrow.circlepath") { sheet = .recovery }
                    if onPaneCommand != nil, sizeClass == .regular {
                        Menu("Panes", systemImage: "rectangle.split.2x1") {
                            Button("Split Pane Right", systemImage: "rectangle.split.2x1") { onPaneCommand?("app.split-right") }
                            Button("Split Pane Below", systemImage: "rectangle.split.1x2") { onPaneCommand?("app.split-below") }
                            if inSplit {
                                Button("Next Pane", systemImage: "arrow.right.square") { onPaneCommand?("app.pane-next") }
                                Button("Close Pane", systemImage: "xmark.square") { onPaneCommand?("app.pane-close") }
                                Button("Close Other Panes", systemImage: "square") { onPaneCommand?("app.pane-only") }
                            }
                        }
                    }
                }
            }
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if let timer = TimerModel.shared.timer {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(timer.modeLine(now: context.date)).font(.callout.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity).padding(4).background(.bar)
                }
                if let message {
                    Text(message).font(.callout).padding(8).frame(maxWidth: .infinity).background(.bar)
                        .onTapGesture { self.message = nil }
                        .task(id: message) {
                            try? await Task.sleep(for: .seconds(4))
                            if self.message == message { self.message = nil }
                        }
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
            case .palette: if let editor { CommandPalette(editor: editor, panes: onPaneCommand != nil && sizeClass == .regular, split: inSplit) { chosen = $0 } }
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
            case .exportSubtree(let caret):
                if let text = session.document(of: path)?.text { SubtreeExportScreen(path: path, text: text, caret: caret) }
            case .backlinks:
                BacklinksScreen(workspace: workspace, session: session, path: path, caret: editor?.editContext().caret ?? 0) { location in
                    if location.path == path { editor?.reveal(location.start) } else { model.openRequest = .heading(location) }
                }
            }
        }
        .fileImporter(isPresented: $importingTable, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            importTable(result)
        }
        .background {
            // A second importer on the same view would replace the first.
            Color.clear.fileImporter(isPresented: Binding(get: { attaching != nil }, set: { if !$0 { attaching = nil } }),
                                     allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                let method = attaching ?? .cp
                switch result {
                case .success(let urls): attachActions.attach(urls, method: method)
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
        .photosPicker(isPresented: $attachingPhotos, selection: $photos, matching: .any(of: [.images, .videos]))
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { data in
                takingPhoto = false
                if let data { attachActions.yankImage(data, ext: "jpg", prefix: "photo") }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            attachPhotos(items)
        }
        .quickLookPreview($previewed)
        .fileExporter(isPresented: Binding(get: { exportedTable != nil }, set: { if !$0 { exportedTable = nil } }),
                      document: exportedTable, contentType: exportedTable?.type ?? .commaSeparatedText,
                      defaultFilename: exportedTable?.type == .tabSeparatedText ? "table.tsv" : "table.csv") { result in
            if case .failure(let error) = result { message = error.localizedDescription } else { message = "Export done." }
        }
        .onChange(of: pane?.conflict) { _, conflict in
            if conflict != nil, isFocused { sheet = .conflict }
        }
        .onChange(of: session.lastError) { _, error in
            if let error { message = error; session.lastError = nil }
        }
        .onAppear(perform: start)
        // A pane command moved focus here.
        .onChange(of: isFocused) {
            guard isFocused, let textView, !textView.isFirstResponder else { return }
            editor?.focus(textView)
            textView.becomeFirstResponder()
        }
        .onChange(of: pane?.revealRequest?.id) {
            if let offset = pane?.revealRequest?.offset, pane?.path == path { editor?.reveal(offset) }
        }
        .onChange(of: model.settingsVersion) {
            editor?.options = editorOptions
            editor?.themeSpec = model.theme
            editor?.keymap = model.keymap
            editor?.modal = model.modalKeys
        }
        .onChange(of: model.showMarkup) { editor?.showMarkup = model.showMarkup }
        .onChange(of: TimerModel.shared.timer) { editor?.options = editorOptions }
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
        let pane: EditorPane
        if let existing = self.pane {
            pane = existing
        } else {
            pane = session.makePane()
            holder.pane = pane
            let store = model.editors, path = path
            holder.release = { [weak session] in
                store.release(pane.id, path: path)
                session?.closePane(pane)
            }
        }
        if pane.path != path { session.open(path, in: pane) }
        model.editors.prune(session)
        guard let editor = model.editors.editor(for: path, session: session, make: makeEditor) else { return }
        let view = model.editors.view(for: pane.id, of: editor)
        editor.onFocus[ObjectIdentifier(view)] = { [weak session] in
            session?.focused = pane
            bind(editor)
            onFocus()
        }
        // A pane a split adds leaves focus where it was, as `split-window` does.
        if isFocused {
            session.focused = pane
            bind(editor)
            editor.focus(view)
        }
        self.editor = editor
        textView = view
        if let offset { editor.reveal(offset) }
        if pane.conflict != nil {
            sheet = .conflict
        } else if case let copies = session.syncConflictCopies().count, copies > 0 {
            message = "\(copies) sync conflict \(copies == 1 ? "copy" : "copies") of this file; More › Sync Conflict Copies compares them."
        }
    }

    private func makeEditor() -> MobileEditor? {
        guard let document = session.document(of: path) else { return nil }
        let editor = MobileEditor(
            document: document, editable: document.isEditable, options: editorOptions, theme: model.theme,
            showMarkup: model.showMarkup, baseDirectory: URL(fileURLWithPath: path).deletingLastPathComponent()
        )
        let path = path
        editor.attachmentPath = { DocumentSession.attachmentPath($0, at: $1, tree: $2, path: path) }
        return editor
    }

    /// The editor's callbacks go to this screen: it's shown here, or its view here took focus.
    private func bind(_ editor: MobileEditor) {
        editor.knownTags = { [index = workspace.index] in (try? index.tags()) ?? [] }
        editor.onChange = { [weak session] in session?.bufferChanged(path) }
        editor.onMessage = { message = $0 }
        editor.onPrompt = { prompt, reply in self.prompt = PromptRequest(prompt: prompt, reply: reply) }
        editor.onLink = { link in follow(link) }
        editor.onEditBlock = { edit in sheet = .block(edit) }
        editor.onColumnView = { view in sheet = .columns(view) }
        editor.onTangle = { scope in message = session.tangle(scope) }
        editor.onBabel = { job in run(job) }
        editor.onRefreshSetup = { session.refreshSetup() }
        editor.onAgenda = { start, count in model.agendaRequest = .init(start: start, count: count) }
        editor.keymap = model.keymap
        editor.modal = model.modalKeys
        // Dropped files are copies the drop made, so they are attached, not linked or opened.
        editor.onFiles = { attachActions.drop($0, method: .attach, attachMethod: .mv) }
        editor.onImage = { attachActions.yankImage($0, ext: $1) }
        editor.onAppCommand = { id in
            if Self.paneCommands.contains(id) {
                if let onPaneCommand { onPaneCommand(id) } else { message = "Not available here" }
            } else if id == "app.save" {
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
            } else if id.hasPrefix("app.attach.") {
                attachActions.run(id)
            } else if id.hasPrefix("app.dailies.") || id.hasPrefix("app.node.") {
                roamActions.run(id)
            } else if id == "app.backlinks" {
                sheet = .backlinks
            } else if id == "app.toggle-markup" {
                model.showMarkup.toggle()
            } else if MobileEditor.linkCommands.contains(id) {
                link(id)
            } else if !MobileClock.run(id, model: model, workspace: workspace, show: { message = $0 }) {
                message = "Not available on iOS yet"
            }
        }
    }
}

extension EditorScreen {
    /// Follows a link; files the editor doesn't open show in Quick Look.
    private func follow(_ link: OrgLink) {
        switch session.follow(link, workspace: workspace, isText: { _ in false }) {
        case .shown:
            // A link to another file shows it on its own screen; this pane keeps its file.
            guard let pane, let target = pane.path, target != path else { message = nil; return }
            let caret = session.caret(of: target) ?? 0
            session.open(path, in: pane)
            model.openRequest = .offset(target, caret)
        case .openExternally(let url): if url.isFileURL { previewed = url } else { openURL(url) }
        case .message(let text): message = text
        }
    }

    /// org-roam's daily notes and nodes.
    private var roamActions: RoamActions {
        RoamActions(
            session: session, roots: { workspace.rootPaths },
            nodes: { workspace.nodes(overlay: workspace.overlay(session.openDocuments)) },
            show: { message = $0 }, ask: { prompt = PromptRequest(prompt: $0, reply: $1) },
            open: { file, offset in
                if file == path { editor?.reveal(offset) } else { model.openRequest = .offset(file, offset) }
            },
            insertLink: { link, title in
                guard let editor else { return }
                let context = editor.editContext()
                let range = context.selection.first ?? context.caret..<context.caret
                let selected = (context.text as NSString).substring(with: NSRange(range))
                let text = Links.makeString(link, selected.isEmpty ? title : selected)
                let end = range.lowerBound + (text as NSString).length
                _ = editor.perform(PrecomputedEdit(EditResult(baseRevision: context.revision, edits: [TextEdit(range: range, replacement: text)], selection: [end..<end])))
            },
            refresh: { Task { await workspace.refresh() } })
    }

    /// org-attach's commands for the entry at the caret.
    private var attachActions: AttachActions {
        AttachActions(
            entry: {
                guard let editor else { return nil }
                let context = editor.editContext()
                return Attachments.Entry(text: context.text, offset: context.caret, path: path, options: context.options)
            },
            apply: { new, caret in
                guard let editor else { return }
                let context = editor.editContext()
                let caret = min(caret ?? context.caret, (new as NSString).length)
                _ = editor.perform(PrecomputedEdit(EditResult(baseRevision: context.revision, edits: TextEdit.between(context.text, new), selection: [caret..<caret])))
            },
            show: { message = $0 },
            ask: { prompt = PromptRequest(prompt: $0, reply: $1) },
            storeLink: { _ = StoredLink.add($0, to: &model.storedLinks) },
            open: { follow(OrgLink(type: "file", path: $0, raw: "file:" + $0)) },
            reveal: { dir in
                if let url = URL(string: "shareddocuments://" + (dir.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dir)) { openURL(url) }
            },
            pick: { attaching = $0 })
    }

    /// Photos and videos attached under the names Photos gives them, linked at the caret.
    private func attachPhotos(_ items: [PhotosPickerItem]) {
        Task { @MainActor in
            var urls: [URL] = []
            for item in items {
                if let picked = try? await item.loadTransferable(type: PickedFile.self) { urls.append(picked.url) }
            }
            if urls.count < items.count { message = "Can't read \(items.count - urls.count) of the items" }
            if !urls.isEmpty { attachActions.drop(urls, method: .attach, attachMethod: .mv) }
        }
    }

    /// `org-table-import`: a TSV, CSV or space-separated file becomes a table at the caret.
    private func importTable(_ result: Result<URL, Error>) {
        guard case .success(let url) = result, let editor else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return message = "Can't read \(url.lastPathComponent)" }
        _ = editor.perform(ImportTable(contents: contents))
    }

    /// The export formats for the subtree at the caret, as the Mac's export sheet's scope.
    private func exportSubtree() {
        guard let context = editor?.editContext() else { return }
        guard ExportScope.subtree(context.text, at: context.caret) != nil else { return message = "Not in a subtree" }
        sheet = .exportSubtree(context.caret)
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
    /// This pane's view of the editor.
    let view: UITextView
    let palette: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let bar = UIHostingController(rootView: KeyBar(editor: editor, palette: palette))
        bar.view.frame = CGRect(x: 0, y: 0, width: 400, height: 48)
        bar.view.backgroundColor = .clear
        bar.sizingOptions = []
        view.inputAccessoryView = bar.view
        context.coordinator.bar = bar
        return view
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
        ("Promote", "decrease.indent", "M-<left>"),
        ("Demote", "increase.indent", "M-<right>"),
        ("Move up", "arrow.up.square", "M-<up>"),
        ("Move down", "arrow.down.square", "M-<down>"),
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
    /// The pane commands are offered (on iPad), and those for more than one pane.
    var panes = false
    var split = false
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
        ("org.toggle-inline-images", "Show or Hide Inline Images"), ("org.latex-preview", "Show or Hide LaTeX Previews"), ("editor.toggle-truncate-lines", "Truncate or Wrap Long Lines"), ("editor.toggle-auto-fill", "Turn Auto Fill On or Off"),
        ("edit.isearch-forward", "Incremental Search"), ("edit.isearch-backward", "Incremental Search Backward"),
        ("org.table.toggle-column-width", "Shrink or Expand Table Column"), ("org.table.shrink", "Shrink Table Columns with Widths"),
        ("org.table.expand", "Expand Table Columns"),
        ("app.table-import", "Import Table from File…"), ("app.table-export", "Export Table to File…"), ("app.plot", "Plot Table"),
        ("app.crypt.encrypt-entry", "Encrypt Entry…"), ("app.crypt.open-entry", "Decrypt Entry…"), ("app.crypt.decrypt-entry", "Decrypt Entry in File…"),
        ("app.crypt.encrypt-entries", "Encrypt Tagged Entries…"), ("app.crypt.forget-passphrase", "Forget Encryption Passphrase"),
        ("app.backlinks", "Show Backlinks"), ("app.node.find", "Find Node…"), ("app.node.insert", "Insert Node Link…"),
        ("app.dailies.today", "Go to Today's Daily Note"), ("app.dailies.yesterday", "Go to Yesterday's Daily Note"),
        ("app.dailies.tomorrow", "Go to Tomorrow's Daily Note"), ("app.dailies.date", "Go to Daily Note for Date…"),
        ("app.dailies.capture-today", "Capture to Today's Daily Note"), ("app.dailies.capture-yesterday", "Capture to Yesterday's Daily Note"),
        ("app.dailies.capture-tomorrow", "Capture to Tomorrow's Daily Note"), ("app.dailies.capture-date", "Capture to Daily Note for Date…"),
        ("app.dailies.next", "Next Daily Note"), ("app.dailies.previous", "Previous Daily Note"),
        ("app.attach.attach", "Attach File…"), ("app.attach.url", "Attach File from URL…"), ("app.attach.new", "New Attachment…"),
        ("app.attach.open", "Open Attachment…"), ("app.attach.reveal", "Show Attachment Folder"), ("app.attach.delete", "Delete Attachment…"),
        ("app.attach.delete-all", "Delete All Attachments…"), ("app.attach.sync", "Sync Attachments"),
        ("app.attach.set-directory", "Set Attachment Folder…"), ("app.attach.unset-directory", "Unset Attachment Folder"),
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
            let paneCommands: [(id: String, title: String)] = !panes ? [] : [("app.split-right", "Split Pane Right"), ("app.split-below", "Split Pane Below")]
                + (split ? [("app.pane-next", "Next Pane"), ("app.pane-close", "Close Pane"), ("app.pane-only", "Close Other Panes")] : [])
            applicable = paneCommands.map { ($0.id, $0.title, editor.keymap.keyLabels(for: $0.id).first) } + (Self.viewCommands + Commands.everything.map { ($0.id, $0.title) })
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
/// A file from the photo picker, copied out of the picker's temporary place with its name.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: url)
            return PickedFile(url: url)
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
/// The pane an editor screen made for itself, closed with the screen.
@MainActor
final class PaneHolder {
    var pane: EditorPane?
    nonisolated(unsafe) var release: (() -> Void)?

    deinit {
        guard let release else { return }
        Task { @MainActor in release() }
    }
}

/// The screen's title, unless a split shows the focused pane's.
private struct EditorTitle: ViewModifier {
    let title: String
    let shown: Bool

    func body(content: Content) -> some View {
        if shown {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}
#endif
