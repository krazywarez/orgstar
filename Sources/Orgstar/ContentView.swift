import AppKit
import OrgApp
import OrgCore
import OrgEditorAppKit
import OrgPresentation
import OrgWorkspace
import OrgIndex
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @Bindable var commands: AppCommands
    let scheduler: ReminderScheduler?
    let clock: ClockModel
    @AppStorage("reminders") private var remindersEnabled = true
    @AppStorage("reminderLead") private var reminderLead = 12
    @AppStorage("clockIdleTime") private var clockIdleTime = 0
    @AppStorage("agendaSubfolders") private var agendaSubfolders = false
    @State private var reminderAgenda: AgendaModel?
    @State private var trust = TrustStore()
    @State private var hotKey: GlobalHotKey?
    @State private var statusItem: ClockStatusItem?
    @AppStorage("globalCapture") private var globalCapture = true
    @State private var hour = 0
    @AppStorage("saveMode") private var saveMode = SaveMode.automatic
    @AppStorage("keymap") private var preset = KeymapPreset.emacs
    @AppStorage("optionAsMeta") private var optionAsMeta = OptionAsMeta.left.rawValue
    @State private var keymap = KeymapPreset.emacs.keymap
    @AppStorage("tagsColumn") private var tagsColumn = -77
    @AppStorage("headingAfterSubtree") private var headingAfterSubtree = true
    @AppStorage("splitLine") private var splitLine = false
    @AppStorage("alphabeticalLists") private var alphabeticalLists = true
    @AppStorage("fillColumn") private var fillColumn = 80
    @AppStorage("hiddenMarkers") private var hiddenMarkers = true
    @AppStorage("prettyEntities") private var prettyEntities = true
    @AppStorage("logDone") private var logDone = "nil"
    @AppStorage("logIntoDrawer") private var logIntoDrawer = ""
    @AppStorage("logReschedule") private var logReschedule = "nil"
    @AppStorage("logRedeadline") private var logRedeadline = "nil"
    @AppStorage("useSpeedCommands") private var useSpeedCommands = false
    @AppStorage("startupWithInlineImages") private var startupWithInlineImages = false
    @AppStorage("startupIndented") private var startupIndented = true
    @AppStorage("hideLeadingStars") private var hideLeadingStars = false
    @AppStorage("startupAlignAllTables") private var startupAlignAllTables = false
    @AppStorage("startupTruncated") private var startupTruncated = false
    @AppStorage("spellCheck") private var spellCheck = false
    @AppStorage("electricPair") private var electricPair = true
    @AppStorage("hideDrawerStartup") private var hideDrawerStartup = true
    @AppStorage("hideBlockStartup") private var hideBlockStartup = false
    @AppStorage("enforceTodoDependencies") private var enforceTodoDependencies = false
    @AppStorage("enforceTodoCheckboxDependencies") private var enforceTodoCheckboxDependencies = false

    /// Bumped when user defaults change, so settings only config.toml has reach `options`.
    @State private var defaultsChanges = 0
    private var options: EditingOptions {
        _ = defaultsChanges
        var options = Preferences.options(
            tagsColumn: tagsColumn, headingAfterSubtree: headingAfterSubtree, splitLine: splitLine, alphabeticalLists: alphabeticalLists,
            fillColumn: fillColumn, hiddenMarkers: hiddenMarkers, prettyEntities: prettyEntities, logDone: logDone, logIntoDrawer: logIntoDrawer,
            hideDrawerStartup: hideDrawerStartup, hideBlockStartup: hideBlockStartup, logReschedule: logReschedule, logRedeadline: logRedeadline,
            useSpeedCommands: useSpeedCommands, startupWithInlineImages: startupWithInlineImages,
            startupIndented: startupIndented, hideLeadingStars: hideLeadingStars, startupAlignAllTables: startupAlignAllTables,
            startupTruncated: startupTruncated, spellCheck: spellCheck, electricPair: electricPair,
            enforceTodoDependencies: enforceTodoDependencies, enforceTodoCheckboxDependencies: enforceTodoCheckboxDependencies
        )
        // The agenda files, for clock tables over `agenda` scopes.
        options.agendaFiles = workspace.agendaFilePaths()
        return options
    }
    /// A block being edited apart (`org-edit-special`).
    @State private var blockEdit: BlockEditRequest?
    /// A sheet a command opened: column view or the export dialog.
    @State private var panel: Panel?

    @State private var selectedFile: String?
    /// A file that isn't text, shown as a preview instead of the open document.
    @State private var previewPath: String?
    @AppStorage("outlineShown") private var orgOutlineShown = true
    @AppStorage("outlineWidth") private var outlineWidth = 220.0
    @AppStorage("backlinksShown") private var backlinksShown = true
    @AppStorage("inspectorShown") private var inspectorShown = false
    @AppStorage("showMarkup") private var showMarkup = false
    @AppStorage("showLineNumbers") private var showLineNumbers = true
    @AppStorage("showHiddenFiles") private var showHiddenFiles = true
    @AppStorage("ignoredFolders") private var ignoredFolders = ScanRules.defaultIgnoredFolders.sorted().joined(separator: " ")
    @AppStorage("themeFont") private var themeFont = ""
    @AppStorage("themeFontSize") private var themeFontSize = 13
    @AppStorage("themeLineSpacing") private var themeLineSpacing = 2
    @AppStorage("themeHeadingStep") private var themeHeadingStep = 1

    /// The theme's colors from config.toml with the type settings.
    private var theme: ThemeSpec {
        var spec = ConfigSync.shared.theme
        spec.font = themeFont
        spec.fontSize = themeFontSize
        spec.lineSpacing = themeLineSpacing
        spec.headingSizeStep = themeHeadingStep
        return spec
    }
    /// The outline for a file that isn't org, off until asked for.
    @State private var plainOutlineShown = false
    @State private var showingImport = false
    @AppStorage("showTabBar") private var showTabBar = false
    /// This window's panes.
    @State private var window: WindowModel?

    private var editorSettings: EditorSettings {
        EditorSettings(keymap: keymap, modal: preset.isModal, optionAsMeta: OptionAsMeta(rawValue: optionAsMeta), options: options, showMarkup: showMarkup, showLineNumbers: showLineNumbers, theme: theme)
    }

    /// The pane that had the focus when a sheet opened, to act on when it closes.
    @State private var sheetTarget: EditorPane?

    /// Puts the focus back on the pane a sheet was opened from.
    private func restoreSheetTarget() {
        guard let target = sheetTarget, session.panes.contains(where: { $0 === target }) else { return }
        sheetTarget = nil
        session.focused = target
        if let window = commands.store.window(of: target.id) { window.focused = target.id }
        if let path = target.path, let textView = commands.store.textView(for: target.id, path: path) {
            textView.window?.makeFirstResponder(textView)
            commands.editor = commands.store.editor(for: path)
        }
    }

    /// The window holding the focused pane: this one, or an editor window.
    private var paneWindow: WindowModel? {
        commands.store.window(of: session.focused.id) ?? window
    }

    /// Gives the focused pane's text view the keyboard, after a pane command moved the focus.
    private func focusPane(_ window: WindowModel) {
        let pane = window.focusedPane
        session.focused = pane
        if let path = pane.path, let textView = commands.store.textView(for: pane.id, path: path) {
            textView.window?.makeFirstResponder(textView)
            commands.editor = commands.store.editor(for: path)
        } else {
            commands.editor = nil
        }
    }
    /// Carets of restored buffers, shown when each first shows.
    @State private var pendingCarets: [String: Int] = [:]
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Whether the outline pane shows: remembered for org files, hidden by default for
    /// other files, and always shown while search results are up.
    private var outlineShown: Bool {
        !query.isEmpty || (previewPath == nil && (session.isOrg ? orgOutlineShown : plainOutlineShown))
    }

    private func toggleOutline() {
        if session.isOrg { orgOutlineShown.toggle() } else { plainOutlineShown.toggle() }
    }

    @ViewBuilder
    private var detail: some View {
        if let previewPath {
            FilePreview(path: previewPath)
        } else if !session.openPaths.isEmpty, let window {
            PaneLayoutView(layout: window.layout, window: window) { pane in
                PaneCell(pane: pane, window: window, session: session, commands: commands, showTabBar: showTabBar, onAppCommand: perform)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ModeLine(session: session, commands: commands, clock: clock, perform: perform)
                    EchoArea(commands: commands)
                }
            }
        } else {
            ContentUnavailableView(
                workspace.roots.isEmpty ? "Add a folder of org files" : "Choose a file",
                systemImage: "doc.text",
                description: Text(workspace.roots.isEmpty ? "File ▸ Add Folder… (⇧⌘O)" : "Or press ⌘P to open one by name.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(outlineShown ? "Hide Outline" : "Show Outline", systemImage: "list.bullet.indent") { toggleOutline() }
                .help(outlineShown ? "Hide the outline (⌥⌘O)" : "Show the outline (⌥⌘O)")
                .disabled(!query.isEmpty || previewPath != nil || session.path == nil)
        }
        if workspace.isIndexing {
            ToolbarItem { ProgressView().controlSize(.small) }
        }
        if let running = clock.running {
            ToolbarItem {
                Menu {
                    Button("Clock Out") { perform("app.clock.out") }
                    Button("Cancel Clock") { perform("app.clock.cancel") }
                    Button("Go to Clocked Entry") { perform("app.clock.goto") }
                    Divider()
                    Button("Clock In to Recent Entry…") { perform("app.clock.in-recent") }
                    Button("Go to Recent Clocked Entry…") { perform("app.clock.goto-recent") }
                    RecentClocks(clock: clock) { perform($0) }
                } label: {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("⏱ \(running.heading) \(clockElapsed(running, now: context.date))").lineLimit(1)
                    }
                }
                .help("Clocked in since \(running.startedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        if session.conflict != nil {
            ToolbarItem {
                Button("Conflict", systemImage: "exclamationmark.triangle") { commands.showingConflict = true }
                    .help("The file changed on disk, and the changes conflict with yours")
            }
        }
    }

    private var main: some View {
        NavigationSplitView {
            Sidebar(workspace: workspace, session: session, selection: $selectedFile) { commands.showingFolderPicker = true }
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            HStack(spacing: 0) {
                if outlineShown {
                    Group {
                        if query.isEmpty {
                            VStack(spacing: 0) {
                                OutlineColumn(session: session)
                                if backlinksShown, session.isOrg {
                                    Divider()
                                    BacklinksPane(workspace: workspace, session: session, commands: commands) { location in
                                        selectedFile = location.path
                                        session.show(location)
                                    }
                                    .frame(height: 200)
                                }
                            }
                        } else {
                            SearchResults(results: workspace.search(query, overlay: workspace.overlay(session.openDocuments))) { location in
                                selectedFile = location.path
                                session.show(location)
                            }
                        }
                    }
                    .frame(width: CGFloat(outlineWidth))
                    PaneDivider(width: $outlineWidth, range: 160...400)
                }
                detail
                    .frame(maxWidth: .infinity)
                    .inspector(isPresented: $inspectorShown) {
                        InspectorPane(session: session, commands: commands)
                            .inspectorColumnWidth(min: 240, ideal: 340, max: 600)
                    }
            }
        }
        .navigationTitle(previewPath.map { ($0 as NSString).lastPathComponent } ?? session.path.map(session.bufferName) ?? "orgstar")
        .navigationSubtitle(session.isReadOnly ? "Read-only: not UTF-8" : "")
        .searchable(text: $query, placement: .toolbar, prompt: "Search notes")
        .searchFocused($searchFocused)
        .toolbar { toolbarItems }
        .onChange(of: session.path) { plainOutlineShown = false }
        .onChange(of: ScanRules(hiddenFiles: showHiddenFiles, ignoredFolders: Set(ignoredFolders.split(separator: " ").map(String.init))), initial: true) { _, rules in
            workspace.scanRules = rules
        }
        .onChange(of: selectedFile) { old, path in
            guard let path else { return }
            if !DocumentSession.isOrgPath(path), !FileTypes.isText(path) {
                previewPath = path
                return
            }
            previewPath = nil
            guard path != session.path else { return }
            session.open(path)
        }
        .onChange(of: session.path) {
            // Buffers switched by keys show in the sidebar too; a restored caret shows once.
            if let path = session.path, selectedFile != path { selectedFile = path }
            if let path = session.path, let caret = pendingCarets.removeValue(forKey: path) { session.reveal(caret) }
            BufferRestore.save(session)
            // Syncthing's conflict copies of the file.
            let copies = session.syncConflictCopies().count
            if copies > 0 { commands.show("\(copies) sync conflict \(copies == 1 ? "copy" : "copies") of this file; Resolve Sync Conflicts compares them.") }
        }
        .onChange(of: session.openPaths) { _, paths in
            BufferRestore.save(session)
            for path in commands.store.editors.keys where !paths.contains(path) { commands.store.releasePath(path) }
        }
        .onChange(of: editorSettings, initial: true) { _, settings in commands.editorSettings = settings }
        .onAppear {
            commands.externalHandler = runExternal
            // `org-clock-out-when-done`, and the notification when the Effort runs out.
            clock.notifications = SystemReminderCenter.isAvailable ? SystemReminderCenter() : nil
            session.textChanged = { [weak session, weak clock, weak commands] path in
                guard let session, let clock, let message = clock.textChanged(path, session) else { return }
                commands?.show(message)
            }
            clock.remindAtEffort(session)
            commands.knownTags = { [index = workspace.index] in (try? index.tags()) ?? [] }
            commands.mainWindowOpen = true
            if let stale = window { commands.store.windows.removeAll { $0 === stale } }
            // The session's first pane the first time; a new one showing the focused buffer
            // when the window opens again.
            let pane: EditorPane
            if commands.store.window(of: session.panes[0].id) == nil, window == nil {
                pane = session.panes[0]
            } else {
                pane = session.makePane()
                if let path = session.focused.path { session.open(path, in: pane) }
            }
            let model = WindowModel(session: session, pane: pane)
            window = model
            commands.store.windows.insert(model, at: 0)
            model.focus(pane.id)
        }
        .onDisappear {
            commands.mainWindowOpen = false
            guard let model = window else { return }
            for id in model.layout.panes { commands.store.releasePane(id) }
            model.closeAll()
            commands.store.windows.removeAll { $0 === model }
            commands.editor = nil
        }
        .onChange(of: saveMode, initial: true) { _, mode in session.saveMode = mode }
        .onChange(of: options, initial: true) { _, options in session.options = options }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in defaultsChanges += 1 }
        .onChange(of: preset, initial: true) { loadKeymap() }
        .sheet(isPresented: $showingImport) { EmacsImportView(workspace: workspace) }
        .sheet(item: $panel) { panel in
            switch panel {
            case .columns(_, let view):
                ColumnViewSheet(view: view) { offset in commands.editor?.reveal(offset) }
            case .export(_, let source):
                ExportSheet(source: source, inSubtree: exportSubtreeAvailable, target: exportTarget) { format, destination, open, subtree, bodyOnly in
                    export(format, to: destination, open: open, subtree: subtree, bodyOnly: bodyOnly)
                }
            case .conflict:
                ConflictSheet(session: session)
            case .syncCopies:
                SyncConflictSheet(session: session) { commands.show($0) }
            case .recovery:
                RecoverySheet(session: session) { commands.show($0) }
            }
        }
        .sheet(item: $blockEdit) { request in
            BlockEditorView(edit: request.edit) { content in
                blockEdit = nil
                guard let content else { return }
                commands.editor?.perform(ReplaceBlockLines(edit: request.edit, content: content))
            }
        }
        .sheet(isPresented: $commands.showingPalette) {
            PaletteView(commands: commands) { id in
                commands.showingPalette = false
                // After the sheet closes, so app commands can present their own, and in the
                // pane that had the focus when it opened: closing a sheet makes this window key.
                DispatchQueue.main.async {
                    restoreSheetTarget()
                    perform(id)
                }
            }
        }
        .onChange(of: commands.showingPalette) { _, showing in if showing { sheetTarget = session.focused } }
        .onChange(of: commands.showingQuickOpen) { _, showing in if showing { sheetTarget = session.focused } }
        .onChange(of: session.conflict) { _, conflict in
            if conflict != nil { commands.showingConflict = true }
        }
        .onChange(of: commands.showingConflict) { _, showing in
            guard showing else { return }
            commands.showingConflict = false
            if session.conflict != nil { panel = .conflict(UUID()) }
        }
        .onChange(of: workspace.changedFile?.version) { fileChangedOnDisk() }
    }

    /// An open file takes in what changed on disk, and a clock started or stopped in Emacs
    /// becomes the one shown.
    private func fileChangedOnDisk() {
        guard let path = workspace.changedFile?.path else { return }
        session.fileChanged(path)
        if path.hasSuffix(".org") { syncClock(paths: [path]) }
    }

    /// Open clocks in `paths`: at launch and as folders load, the agenda files.
    private func syncClock(paths: [String]) {
        guard !workspace.files.isEmpty, let message = clock.sync(session, paths: paths) else { return }
        commands.show(message)
    }

    var body: some View {
        main
        .task(id: workspace.files.count) { syncClock(paths: workspace.agendaFilePaths()) }
        .onChange(of: ClockMenuState(running: clock.running, history: clock.history), initial: true) { _, state in
            if statusItem == nil { statusItem = ClockStatusItem { commands.run($0) } }
            statusItem?.update(state.running, recent: state.history.map(\.title))
        }
        .onChange(of: globalCapture, initial: true) { _, enabled in
            hotKey?.unregister()
            hotKey = enabled ? GlobalHotKey { perform("app.capture") } : nil
        }
        .onChange(of: commands.runRequest?.serial, initial: true) {
            if let id = commands.runRequest?.id { perform(id) }
        }
        .onChange(of: ConfigSync.shared.problems, initial: true) { _, problems in
            if let first = problems.first {
                commands.show(first + (problems.count > 1 ? " (and \(problems.count - 1) more)" : ""))
            }
        }
        .onChange(of: ConfigSync.shared.changedFile?.serial) {
            if ConfigSync.shared.changedFile?.name == "keymap.toml" { loadKeymap() }
        }
        .onChange(of: commands.jumpRequest?.id) {
            guard let request = commands.jumpRequest else { return }
            if request.path != session.path {
                session.open(request.path)
                selectedFile = request.path
            }
            session.reveal(request.offset)
        }
        .onChange(of: commands.focusSearch) { _, focus in
            if focus {
                searchFocused = true
                commands.focusSearch = false
            }
        }
        .fileImporter(isPresented: $commands.showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { try await workspace.addRoot(url) } catch { workspace.lastError = error.localizedDescription }
            }
        }
        .sheet(isPresented: $commands.showingQuickOpen) {
            QuickOpenView(workspace: workspace) { entry in
                commands.showingQuickOpen = false
                DispatchQueue.main.async {
                    restoreSheetTarget()
                    selectedFile = entry.path
                    if selectedFile == entry.path { session.open(entry.path) }
                }
            }
        }
        .alert("orgstar", isPresented: errorShown) {
            Button("OK") {
                workspace.lastError = nil
                session.lastError = nil
            }
        } message: {
            Text(workspace.lastError ?? session.lastError ?? "")
        }
        .task(id: ReminderKey(
            enabled: remindersEnabled, lead: reminderLead, subfolders: agendaSubfolders, files: workspace.files.count,
            changed: workspace.changedFile?.version, edits: session.editVersion, hour: hour
        )) {
            await updateReminders()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                hour += 1
            }
        }
        // `org-resolve-clocks-if-idle`, checked every minute while a clock runs.
        .task(id: "\(clock.running?.start ?? "") \(clockIdleTime)") {
            guard clock.running != nil, clockIdleTime > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, clock.running != nil, !clock.isResolving else { continue }
                let idle = ClockIdle.seconds()
                guard idle > Double(clockIdleTime * 60) else { continue }
                NSApp.requestUserAttention(.informationalRequest)
                report(await clock.resolveIdle(session, idleSince: Date().addingTimeInterval(-idle), ask: askClock))
            }
        }
        .task {
            DevelopmentHooks.scheduleSnapshot()
            pendingCarets = BufferRestore.restore(session)
            if let path = session.path, let caret = pendingCarets.removeValue(forKey: path) { session.reveal(caret) }
            // Files handed over at launch open after the restored buffers, and show.
            for path in AppDelegate.pendingOpens { session.open(path) }
            AppDelegate.pendingOpens = []
            for link in AppDelegate.pendingLinks + [DevelopmentHooks.urlToOpen].compactMap({ $0 }) { commands.handle(protocolURL: link) }
            AppDelegate.pendingLinks = []
            if let path = DevelopmentHooks.fileToOpen { selectedFile = path }
            if let root = DevelopmentHooks.rootToAdd { try? await workspace.addRoot(URL(fileURLWithPath: root)) }
            if let commandList = DevelopmentHooks.commandToRun {
                // The file opened above needs its editor first.
                for _ in 0..<20 where DevelopmentHooks.fileToOpen != nil && commands.editor == nil { try? await Task.sleep(for: .milliseconds(100)) }
                for command in commandList.split(separator: ",") { perform(String(command)) }
                for answer in DevelopmentHooks.answers {
                    for _ in 0..<20 where commands.prompt == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    commands.answer(answer)
                }
            }
            if let id = DevelopmentHooks.windowToOpen {
                if id == "settings" { openSettings() } else { openWindow(id: id) }
            }
            await workspace.refresh()
            workspace.startWatching()
        }
    }

    /// The selection, or the whole file without one, on the clipboard as HTML, RTF and plain
    /// text, to paste formatted into mail and documents.
    private func copyRichText() {
        guard let path = session.path, let whole = session.document?.text, let editor = commands.editor else { return commands.show("No file is open") }
        let defaults = Preferences.orgSettings.resolvingSetupFiles(in: whole, path: path, read: OrgSettings.readFile)
        let selection = editor.context().selection.first { !$0.isEmpty }
        let selected = selection.map { (whole as NSString).substring(with: NSRange($0)) }
        let url = URL(fileURLWithPath: path)
        let html = HTMLExport.page(
            selected ?? whole, fallbackTitle: url.deletingPathExtension().lastPathComponent, settings: defaults, path: path, bodyOnly: selected != nil,
            codeStyle: HTMLCodeStyle(highlighter: PaneView.highlighter, theme: theme)
        )
        do {
            try RichTextExport.copy(html: html, directory: url.deletingLastPathComponent())
            commands.show(selected == nil ? "Copied the file as rich text" : "Copied the selection as rich text")
        } catch {
            commands.show("\(error)")
        }
    }

    /// Whether the caret is in a heading's subtree, which the export dialog can export alone.
    private var exportSubtreeAvailable: Bool {
        guard let text = session.document?.text, let caret = commands.editor?.context().caret else { return false }
        return ExportScope.subtree(text, at: caret) != nil
    }

    /// Where an export goes by default: `#+EXPORT_FILE_NAME`, or the subtree's
    /// `EXPORT_FILE_NAME`, else beside the file, with `ext`.
    private func exportTarget(_ ext: String, subtree: Bool) -> URL {
        let path = session.path ?? ""
        let text = session.document?.text ?? ""
        let caret = subtree ? commands.editor?.context().caret : nil
        return ExportScope.output(for: URL(fileURLWithPath: path), name: ExportScope.fileName(text, subtreeAt: caret), extension: ext)
    }

    /// Writes the export where `#+EXPORT_FILE_NAME` says or beside the file, as Emacs's export
    /// dispatcher does, or to `destination`, and opens it with `open`. `subtree` exports the
    /// subtree at the caret alone; `bodyOnly` leaves out the title and page wrapper.
    private func export(_ format: String, to destination: URL? = nil, open: Bool = false, subtree: Bool = false, bodyOnly: Bool = false) {
        guard let path = session.path, var text = session.document?.text else {
            commands.show("No file is open")
            return
        }
        let url = URL(fileURLWithPath: path)
        let base = url.deletingPathExtension()
        let defaults = Preferences.orgSettings.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile)
        let open = open || format == "html-open"
        let caret = commands.editor?.context().caret ?? 0
        let whole = text
        if subtree {
            guard let narrowed = ExportScope.subtree(text, at: caret, settings: defaults) else { return commands.show("Not in a subtree") }
            text = narrowed
        }
        switch format {
        case "html", "html-open", "markdown":
            let name = ExportScope.fileName(whole, subtreeAt: subtree ? caret : nil, settings: defaults)
            let target = destination ?? ExportScope.output(for: url, name: name, extension: format == "markdown" ? "md" : "html")
            let content = format == "markdown"
                ? MarkdownExport.document(text, settings: defaults, path: path, bodyOnly: bodyOnly)
                : HTMLExport.page(
                    text, fallbackTitle: base.lastPathComponent, settings: defaults, path: path, bodyOnly: bodyOnly,
                    codeStyle: HTMLCodeStyle(highlighter: PaneView.highlighter, theme: theme)
                )
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, atomically: true, encoding: .utf8)
                commands.show("Exported to \(target.lastPathComponent)")
                if open { NSWorkspace.shared.open(target) }
            } catch {
                commands.show("Can't write \(target.lastPathComponent): \(error.localizedDescription)")
            }
        case "print-pdf", "docx", "rtf", "plain-text":
            let ext = ["print-pdf": "pdf", "plain-text": "txt"][format] ?? format
            let name = ExportScope.fileName(whole, subtreeAt: subtree ? caret : nil, settings: defaults)
            let target = destination ?? ExportScope.output(for: url, name: name, extension: ext)
            let html = HTMLExport.page(
                text, fallbackTitle: base.lastPathComponent, settings: defaults, path: path,
                codeStyle: HTMLCodeStyle(highlighter: PaneView.highlighter, theme: theme)
            )
            let directory = url.deletingLastPathComponent()
            if format == "print-pdf" { commands.show("Exporting to PDF…") }
            Task {
                do {
                    let data: Data
                    switch format {
                    case "print-pdf": data = try await PDFExport.pdf(html: html, directory: directory)
                    case "docx": data = try RichTextExport.docx(RichTextExport.attributed(html: html, directory: directory))
                    case "rtf": data = try RichTextExport.rtf(RichTextExport.attributed(html: html, directory: directory))
                    default: data = Data(RichTextExport.plain(try RichTextExport.attributed(html: html, directory: directory)).utf8)
                    }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                    commands.show("Exported to \(target.lastPathComponent)")
                    if open { NSWorkspace.shared.open(target) }
                } catch {
                    commands.show("Can't export \(target.lastPathComponent): \(error)")
                }
            }
        default:
            let functions = ["pdf": "org-latex-export-to-pdf", "odt": "org-odt-export-to-odt", "latex": "org-latex-export-to-latex", "text": "org-ascii-export-to-ascii"]
            guard let function = functions[format] else { return }
            commands.show("Exporting with Emacs…")
            commands.runInEmacs {
                do {
                    // Emacs narrows to the subtree and reads EXPORT_FILE_NAME itself.
                    let point = subtree ? (whole as NSString).substring(to: min(caret, (whole as NSString).length)).unicodeScalars.count + 1 : nil
                    var written = URL(fileURLWithPath: try await EmacsRunner.export(
                        text: whole, path: path, function: function, subtree: point, bodyOnly: bodyOnly
                    ))
                    if let destination, destination.standardizedFileURL != written.standardizedFileURL {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: written, to: destination)
                        written = destination
                    }
                    commands.show("Exported to \(written.lastPathComponent)")
                    if open { NSWorkspace.shared.open(written) }
                } catch is CancellationError {
                    commands.show("Export canceled")
                } catch {
                    commands.show("\(error)")
                }
            }
        }
    }

    /// Work a command hands to the platform: tables recalculated in Emacs.
    private func runExternal(_ request: ExternalRequest) {
        switch request {
        case .openLink(let link):
            if let message = LinkOpener.open(link, session: session, workspace: workspace) { commands.show(message) }
            // `org-occur` for a regexp link, once the editor shows the file.
            if let regexp = Links.regexpSearch(link) {
                DispatchQueue.main.async { commands.editor?.perform(SparseTreeCommand(), answers: ["sparse": "/", "regexp": regexp]) }
            }
        case .tangle(let scope):
            commands.show(session.tangle(scope))
        case .agenda(let start, let days):
            commands.agendaRequest = (start, days)
            openWindow(id: "agenda")
        case .editBlock(let edit):
            blockEdit = BlockEditRequest(edit: edit)
        case .columnView(let view):
            panel = .columns(UUID(), view)
        case .emacsTable(let table, let point, let form, let reason, let lisp):
            let run = {
                commands.show("Recalculating in Emacs (\(reason))…")
                commands.runInEmacs { commands.show(await session.recalculateInEmacs(table: table, point: point, form: form)) }
            }
            guard lisp, let path = session.path, let text = session.document?.text else { return run() }
            let content = (text as NSString).substring(with: NSRange(location: table.lowerBound, length: min((text as NSString).length, table.upperBound + 2000) - table.lowerBound))
            if trust.isTrusted(path: path, content: content) { return run() }
            commands.ask(Prompt(key: "confirm", message: "This table's formulas run Lisp. Run them? (yes, no, always)", choices: ["yes", "no", "always"])) { answer in
                switch answer {
                case "always":
                    trust.trust(path: path, content: content)
                    run()
                case "yes": run()
                default: commands.show("Not recalculated")
                }
            }
        case .babel(let job):
            let run = {
                commands.show("Running \(job.language) block… (⌘. to cancel)")
                session.startBabel(job) { commands.show($0) }
            }
            guard let path = session.path else { return }
            if !job.alwaysAsk, trust.isTrusted(path: path, content: job.blockText) { return run() }
            let choices = job.alwaysAsk ? ["yes", "no"] : ["yes", "no", "always"]
            commands.ask(Prompt(key: "confirm", message: "Run this \(job.language) block? (\(choices.joined(separator: ", ")))", choices: choices)) { answer in
                switch answer {
                case "always":
                    trust.trust(path: path, content: job.blockText)
                    run()
                case "yes": run()
                default: commands.show("Not run")
                }
            }
        }
    }

    private struct ReminderKey: Hashable {
        var enabled: Bool
        var lead: Int
        var subfolders: Bool
        var files: Int
        var changed: Int?
        var edits: Int
        var hour: Int
    }

    /// Sets the notifications for the next week's timed entries, once edits pause.
    private func updateReminders() async {
        guard let scheduler else { return }
        guard remindersEnabled else {
            await scheduler.clear()
            return
        }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, !workspace.files.isEmpty else { return }
        let agenda = reminderAgenda ?? AgendaModel(workspace: workspace)
        reminderAgenda = agenda
        agenda.includeSubfolders = agendaSubfolders
        let open = session.openTexts
        let reminders = await agenda.reminders(open: open, lead: reminderLead)
        guard !Task.isCancelled else { return }
        await scheduler.reconcile(reminders)
    }

    private func loadKeymap() {
        let loaded = KeymapLoader.load(preset, commands: Set(EditorCommands.all.map(\.id)))
        keymap = loaded.keymap
        commands.keymap = loaded.keymap
        commands.modal = preset.isModal
        if let first = loaded.problems.first {
            let more = loaded.problems.count > 1 ? " (and \(loaded.problems.count - 1) more)" : ""
            commands.show("keymap.toml: \(first)\(more)")
        }
    }

    /// `SPC b b`: open buffers, most recent first, by name (with the folder when names repeat).
    private func switchBuffer() {
        let paths = session.recentPaths.dropFirst() + session.recentPaths.prefix(1)
        let labels = paths.map(session.bufferName)
        guard !labels.isEmpty else { return commands.show("No buffers are open") }
        commands.ask(Prompt(key: "buffer", message: "Switch to buffer:", choices: labels)) { answer in
            guard let answer, let index = labels.firstIndex(of: answer) else { return }
            session.open(Array(paths)[index])
        }
    }

    /// Runs a command from a key, the palette or the Org menu.
    private func perform(_ id: String) {
        let orgOnly = ["app.refile", "app.refile.copy", "app.archive", "app.clock.in", "app.clock.default", "app.copy-rich-text"].contains(id) || id.hasPrefix("app.export.") || id.hasPrefix("org.")
        if orgOnly, !session.isOrg {
            commands.show("Not an org file")
            return
        }
        switch id {
        case "app.save":
            if !session.save(), session.conflict != nil { commands.showingConflict = true }
        case "app.quit": NSApp.terminate(nil)
        case "app.save-all":
            if !session.saveAll(), session.conflict != nil { commands.showingConflict = true }
        case "app.buffer.switch": switchBuffer()
        case "app.buffer.next": session.cycle(1)
        case "app.buffer.previous": session.cycle(-1)
        case "app.buffer.last": session.showPrevious()
        case "app.buffer.kill":
            guard let path = session.path else {
                NSApp.keyWindow?.performClose(nil)
                return
            }
            if UnsavedChanges.resolve(session) { session.kill(path) }
        case "app.buffer.kill-others":
            let others = session.openPaths.filter { $0 != session.path }
            if UnsavedChanges.resolve(session, paths: others) { others.forEach(session.kill) }
        case "app.buffer.kill-all":
            let all = session.openPaths
            if UnsavedChanges.resolve(session, paths: all) { all.forEach(session.kill) }
        case "app.toggle-tab-bar": showTabBar.toggle()
        case "app.split-below": paneWindow?.split(.vertical)
        case "app.split-right": paneWindow?.split(.horizontal)
        case "app.pane-close":
            guard let window = paneWindow, window.paneCount > 1 else { return commands.show("Attempt to delete the only pane") }
            commands.store.releasePane(window.focused)
            window.close(window.focused)
            focusPane(window)
        case "app.pane-only":
            guard let window = paneWindow else { return }
            for id in window.layout.panes where id != window.focused { commands.store.releasePane(id) }
            window.closeOthers()
            focusPane(window)
        case "app.pane-next":
            guard let window = paneWindow else { return }
            window.focusNext()
            focusPane(window)
        case "app.window-new": openWindow(id: "editor")
        case "app.babel.cancel":
            if session.isRunningBabel {
                session.cancelBabel()
            } else if let task = commands.emacsTask {
                task.cancel()
            } else {
                commands.show("Nothing is running")
            }
        case "app.toggle-outline": toggleOutline()
        case "app.toggle-backlinks": backlinksShown.toggle()
        case "app.toggle-inspector": inspectorShown.toggle()
        case "app.toggle-markup": showMarkup.toggle()
        case "app.toggle-line-numbers": showLineNumbers.toggle()
        case "app.import-emacs": showingImport = true
        case "app.edit-config": commands.jump(path: UserConfig.configFile.path, offset: 0)
        case "app.quick-open": commands.showingQuickOpen = true
        case "app.palette": commands.showingPalette = true
        case "app.search": commands.focusSearch = true
        case "app.reload-keymap":
            loadKeymap()
            commands.show("Keymap reloaded")
        case "app.refile", "app.refile.copy":
            let keep = id == "app.refile.copy"
            let targets = workspace.refileTargets(openPath: session.path, document: session.document)
            commands.ask(Prompt(key: "refile", message: keep ? "Copy to:" : "Refile to:", choices: targets.map(\.label))) { answer in
                guard let answer else { return }
                if let target = targets.first(where: { $0.label == answer }) {
                    if let message = session.refile(to: target, keep: keep) { commands.show(message) }
                    return
                }
                // `org-refile-allow-creating-parent-nodes`: `parent/new` adds the heading first.
                let creating = OrgPreferences.refileSettings().creating
                guard creating != .no, let (parent, child) = RefileSettings.newNode(answer, in: targets) else { return commands.show("Invalid target location") }
                let create = {
                    switch session.createRefileChild(under: parent, title: child) {
                    case .success(let target): if let message = session.refile(to: target, keep: keep) { commands.show(message) }
                    case .failure(.message(let message)): commands.show(message)
                    }
                }
                guard creating == .confirm else { return create() }
                commands.ask(Prompt(key: "confirm", message: "Create new node \"\(child)\"?", choices: ["yes", "no"])) { reply in
                    if reply == "yes" { create() }
                }
            }
        case "app.refile.goto":
            // `C-u C-c C-w`: the target heading, or the end of a file.
            let targets = workspace.refileTargets(openPath: session.path, document: session.document)
            commands.ask(Prompt(key: "refile", message: "Goto:", choices: targets.map(\.label))) { answer in
                guard let answer, let target = targets.first(where: { $0.label == answer }) else { return }
                commands.jump(path: target.path, offset: target.start ?? Int.max)
            }
        case "app.archive":
            if let message = session.archive() { commands.show(message) }
        case "app.table-import":
            // `org-table-import`: a TSV, CSV or space-separated file becomes a table at point.
            guard let editor = commands.editor else { return commands.show("No file is open") }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return commands.show("Can't read \(url.lastPathComponent)") }
            editor.perform(ImportTable(contents: contents))
        case "app.table-export":
            // `org-table-export`: CSV for a .csv name, else TSV.
            guard let editor = commands.editor else { return commands.show("No file is open") }
            let context = editor.context()
            guard ImportTable.exportText(context.text, at: context.caret, path: "") != nil else { return commands.show("No table at point") }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "table.csv"
            guard panel.runModal() == .OK, let url = panel.url,
                  let text = ImportTable.exportText(context.text, at: context.caret, path: url.path) else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                commands.show("Export done.")
            } catch {
                commands.show("File not written: \(error.localizedDescription)")
            }
        case "org.subtree.paste":
            guard let text = NSPasteboard.general.string(forType: .string) else { return commands.show("The clipboard is empty") }
            commands.editor?.perform(PasteSubtree(text: text))
        case "org.link.insert":
            commands.editor?.perform(InsertLink(stored: commands.storedLinks, file: session.path))
        case "org.link.store":
            guard let editor = commands.editor, let path = session.path else { return commands.show("No method for storing a link from this buffer") }
            commands.storeLink(Links.store(in: editor.context(), path: Links.abbreviate(path, home: NSHomeDirectory())))
        case "org.id.store-link":
            guard let editor = commands.editor, let path = session.path else { return }
            if case .commit = editor.perform(CreateID()),
               let link = Links.storeID(in: editor.context(), fileName: (path as NSString).lastPathComponent) {
                commands.storeLink(link)
            }
        case "app.agenda":
            openWindow(id: "agenda")
        case "app.clock.in":
            clockIn(.caret)
        case "app.clock.in-recent":
            clockIn(.select)
        case "app.clock.in-last":
            clockIn(.last)
        case let id where id.hasPrefix("app.clock.history."):
            if let index = Int(id.dropFirst("app.clock.history.".count)), index < clock.history.count { clockIn(.task(clock.history[index])) }
        case "app.clock.out":
            commands.show(clock.clockOut(session))
        case "app.clock.cancel":
            commands.show(clock.clockOut(session, cancel: true))
        case "app.clock.goto":
            let found = clock.goto(session)
            if let location = found.location { commands.jump(path: location.path, offset: location.offset) }
            if let message = found.message { commands.show(message) }
        case "app.clock.goto-recent":
            Task {
                let found = await clock.gotoRecent(session, ask: askClock)
                if let location = found.location { commands.jump(path: location.path, offset: location.offset) }
                if let message = found.message { commands.show(message) }
            }
        case "app.clock.default":
            commands.show(clock.markDefault(session))
        case "app.clock.resolve":
            Task { report(await clock.resolveOpenClocks(session, paths: orgFiles, ask: askClock)) }
        case "app.clock.report":
            openWindow(id: "clock-report")
        case "app.board":
            openWindow(id: "board")
        case "app.capture":
            NSApp.activate()
            openWindow(id: "capture")
        case "app.revert":
            // `:e`: the file as it is on disk; unsaved changes go to recovery.
            guard session.path != nil else { return commands.show("No file is open") }
            session.useDiskVersion()
            commands.show("Reverted to the file on disk")
        case "app.sync-conflicts":
            guard session.path != nil else { return commands.show("No file is open") }
            panel = .syncCopies(UUID())
        case "app.recovery":
            guard session.path != nil else { return commands.show("No file is open") }
            panel = .recovery(UUID())
        case "app.copy-rich-text":
            copyRichText()
        case "app.export-dialog":
            guard let path = session.path else { return commands.show("No file is open") }
            panel = .export(UUID(), URL(fileURLWithPath: path))
        case let id where id.hasPrefix("app.export."):
            export(String(id.dropFirst("app.export.".count)))
        default:
            if let editor = commands.editor { editor.run(id) } else { commands.show("No file is open") }
        }
    }

    private var askClock: ClockModel.Ask { commands.askClock }

    /// The files `org-resolve-clocks` looks through: the workspace's org files.
    private var orgFiles: [String] { workspace.files.filter { $0.kind == .org }.map(\.path) }

    private func clockIn(_ target: ClockModel.Target) {
        Task { report(await clock.clockIn(session, target: target, paths: orgFiles, ask: askClock)) }
    }

    /// The last message of a clock command, and the clock to show for `j`.
    private func report(_ outcome: ClockModel.Outcome) {
        if let jump = outcome.jump { commands.jump(path: jump.path, offset: jump.offset) }
        if let message = outcome.messages.last(where: { !$0.isEmpty }) { commands.show(message) }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { workspace.lastError != nil || session.lastError != nil }, set: { _ in })
    }
}
