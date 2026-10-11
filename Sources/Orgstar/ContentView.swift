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

    private var options: EditingOptions {
        Preferences.options(
            tagsColumn: tagsColumn, headingAfterSubtree: headingAfterSubtree, splitLine: splitLine, alphabeticalLists: alphabeticalLists,
            fillColumn: fillColumn, hiddenMarkers: hiddenMarkers, prettyEntities: prettyEntities, logDone: logDone, logIntoDrawer: logIntoDrawer,
            hideDrawerStartup: hideDrawerStartup, hideBlockStartup: hideBlockStartup, logReschedule: logReschedule, logRedeadline: logRedeadline,
            useSpeedCommands: useSpeedCommands, startupWithInlineImages: startupWithInlineImages,
            startupIndented: startupIndented, hideLeadingStars: hideLeadingStars, startupAlignAllTables: startupAlignAllTables,
            startupTruncated: startupTruncated, spellCheck: spellCheck, electricPair: electricPair,
            enforceTodoDependencies: enforceTodoDependencies, enforceTodoCheckboxDependencies: enforceTodoCheckboxDependencies
        )
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
        } else if session.path != nil {
            VStack(spacing: 0) {
                if showTabBar { BufferTabs(session: session) }
                EditorView(session: session, commands: commands, keymap: keymap, modal: preset.isModal, optionAsMeta: OptionAsMeta(rawValue: optionAsMeta), options: options, showMarkup: showMarkup, showLineNumbers: showLineNumbers, theme: theme, onAppCommand: perform, onExternal: runExternal, knownTags: { [index = workspace.index] in (try? index.tags()) ?? [] })
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
        .onChange(of: session.openPaths) { BufferRestore.save(session) }
        .onChange(of: saveMode, initial: true) { _, mode in session.saveMode = mode }
        .onChange(of: options, initial: true) { _, options in session.options = options }
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
                // After the sheet closes, so app commands can present their own.
                DispatchQueue.main.async { perform(id) }
            }
        }
        .onChange(of: session.conflict) { _, conflict in
            if conflict != nil { commands.showingConflict = true }
        }
        .onChange(of: commands.showingConflict) { _, showing in
            guard showing else { return }
            commands.showingConflict = false
            if session.conflict != nil { panel = .conflict(UUID()) }
        }
        .onChange(of: workspace.changedFile?.version) {
            if let path = workspace.changedFile?.path { session.fileChanged(path) }
        }
    }

    var body: some View {
        main
        .onChange(of: ClockMenuState(running: clock.running, history: clock.history), initial: true) { _, state in
            if statusItem == nil { statusItem = ClockStatusItem { commands.run($0) } }
            statusItem?.update(state.running, recent: state.history.map(\.title))
        }
        .onChange(of: globalCapture, initial: true) { _, enabled in
            hotKey?.unregister()
            hotKey = enabled ? GlobalHotKey { perform("app.capture") } : nil
        }
        .onChange(of: commands.runRequest?.serial) {
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
                selectedFile = entry.path
                commands.showingQuickOpen = false
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
                    codeStyle: HTMLCodeStyle(highlighter: EditorView.highlighter, theme: theme)
                )
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: target, atomically: true, encoding: .utf8)
                commands.show("Exported to \(target.lastPathComponent)")
                if open { NSWorkspace.shared.open(target) }
            } catch {
                commands.show("Can't write \(target.lastPathComponent): \(error.localizedDescription)")
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
        let orgOnly = ["app.refile", "app.archive", "app.clock.in", "app.clock.default"].contains(id) || id.hasPrefix("app.export.") || id.hasPrefix("org.")
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
        case "app.refile":
            let targets = workspace.refileTargets(openPath: session.path, document: session.document)
            commands.ask(Prompt(key: "refile", message: "Refile to:", choices: targets.map(\.label))) { answer in
                guard let answer, let target = targets.first(where: { $0.label == answer }) else { return }
                if let message = session.refile(to: target) { commands.show(message) }
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

struct Sidebar: View {
    let workspace: WorkspaceModel
    let session: DocumentSession
    @Binding var selection: String?
    var addFolder: () -> Void = {}
    /// Folders shown collapsed, by path, one per line.
    @AppStorage("collapsedFolders") private var collapsedText = ""
    @State private var removing: String?
    /// A file operation waiting for a name or a confirmation.
    @Environment(\.orgTheme) private var theme
    @State var pending: FileOperation?
    @State var name = ""
    @State var failure: String?

    private var collapsed: Set<String> { Set(collapsedText.split(separator: "\n").map(String.init)) }

    private func expanded(_ root: String) -> Binding<Bool> {
        Binding {
            !collapsed.contains(root)
        } set: { isExpanded in
            var set = collapsed
            if isExpanded { set.remove(root) } else { set.insert(root) }
            collapsedText = set.sorted().joined(separator: "\n")
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(workspace.rootPaths, id: \.self) { root in
                Section(isExpanded: expanded(root)) {
                    OutlineGroup(workspace.tree(forRoot: root).children ?? [], children: \.children) { node in
                        Label(node.name, systemImage: icon(node))
                            .foregroundStyle(node.file?.kind == .conflict ? .orange : node.isDownloading ? .secondary : theme.color("sidebar-foreground") ?? .primary)
                            .help(node.isDownloading ? "Downloading from iCloud" : "")
                            .tag(node.file?.path)
                            .contextMenu { fileMenu(node) }
                    }
                } header: {
                    Text((root as NSString).lastPathComponent)
                        .foregroundStyle(theme.color("sidebar-header") ?? .secondary)
                        .help(root)
                        .contextMenu { folderMenu(root) }
                }
            }
        }
        .listStyle(.sidebar)
        .themedListBackground(theme.color("sidebar-background"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button("Add Folder…", systemImage: "plus", action: addFolder)
                    .help("Add a folder (⇧⌘O)")
                Menu {
                    ForEach(workspace.rootPaths, id: \.self) { root in
                        Button((root as NSString).lastPathComponent) { removing = root }
                    }
                } label: {
                    Label("Remove Folder", systemImage: "minus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(workspace.rootPaths.isEmpty)
                .help("Remove a folder from the sidebar")
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .confirmationDialog(
            "Remove “\(removing.map { ($0 as NSString).lastPathComponent } ?? "")” from the sidebar?",
            isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } }
        ) {
            Button("Remove") {
                if let root = removing { try? workspace.removeRoot(path: root) }
                removing = nil
            }
        } message: {
            Text("The folder and its files stay on disk.")
        }
        .fileOperations(self)
    }

    @ViewBuilder
    private func folderMenu(_ root: String) -> some View {
        Button("New File…") { ask(.create(folder: root)) }
        Divider()
        Button(collapsed.contains(root) ? "Expand" : "Collapse") { expanded(root).wrappedValue.toggle() }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root)]) }
        Divider()
        Button("Remove from Sidebar…") { removing = root }
    }

    private func icon(_ node: FileTreeNode) -> String {
        if node.isDownloading { return "icloud.and.arrow.down" }
        guard let file = node.file else { return "folder" }
        switch file.kind {
        case .org: return "doc.text"
        case .archive: return "archivebox"
        case .conflict: return "exclamationmark.triangle"
        case .other:
            guard let type = UTType(filenameExtension: (file.path as NSString).pathExtension) else { return "doc" }
            if type.conforms(to: .image) { return "photo" }
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .audiovisualContent) { return "play.rectangle" }
            if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
            if type.conforms(to: .text) { return "doc.plaintext" }
            return "doc"
        }
    }
}

struct OutlineColumn: View {
    let session: DocumentSession
    @Environment(\.orgTheme) private var theme

    var body: some View {
        List(Array(session.outline.enumerated()), id: \.element.start) { _, entry in
            Button {
                session.reveal(entry.start)
            } label: {
                Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                    .foregroundStyle(theme.color("sidebar-foreground") ?? .primary)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(entry.level - 1) * 12)
            }
            .buttonStyle(.plain)
        }
        .themedListBackground(theme.color("sidebar-background"))
        .overlay {
            if session.path != nil, !session.isOrg {
                ContentUnavailableView("No outline", systemImage: "doc.plaintext", description: Text("Only org files have an outline."))
            } else if session.path != nil, session.outline.isEmpty {
                ContentUnavailableView("No headings", systemImage: "list.bullet.indent")
            }
        }
    }
}

struct SearchResults: View {
    let results: [HeadingLocation]
    let open: (HeadingLocation) -> Void

    var body: some View {
        List(results, id: \.self) { location in
            Button {
                open(location)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title.isEmpty ? "(untitled)" : location.title).lineLimit(1)
                    Text((location.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if results.isEmpty { ContentUnavailableView.search }
        }
    }
}

struct QuickOpenView: View {
    let workspace: WorkspaceModel
    let open: (FileEntry) -> Void
    @State private var query = ""
    /// The highlighted match, moved by ↑/↓ or C-p/C-n and opened by Return.
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let matches = workspace.quickOpen(query)
        let current = min(selected, matches.count - 1)
        VStack(spacing: 0) {
            TextField("Open file", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .onSubmit { if current >= 0 { open(matches[current]) } }
                .onKeyPress(phases: .down) { press in
                    let control = press.modifiers == .control
                    let step = if press.key == .downArrow || control && press.characters == "n" { 1 }
                        else if press.key == .upArrow || control && press.characters == "p" { -1 } else { 0 }
                    guard step != 0 else { return .ignored }
                    selected = max(0, min(current + step, matches.count - 1))
                    return .handled
                }
                .onChange(of: query) { selected = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(matches.indices, id: \.self) { index in
                    let entry = matches[index]
                    Button {
                        open(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.relativePath).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(index == current ? Color.accentColor.opacity(0.25) : Color.clear)
                    .accessibilityAddTraits(index == current ? .isSelected : [])
                }
                .onChange(of: current) { if current >= 0 { proxy.scrollTo(current) } }
            }
        }
        .frame(width: 520, height: 360)
        .onExitCommand { dismiss() }
    }
}

/// A divider that resizes the pane before it by dragging. An `HSplitView` inside the window's
/// split view loops on its size constraints in short windows, so this sets a width instead.
struct PaneDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(Color.clear.frame(width: 7).contentShape(Rectangle()).onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let base = start ?? width
                start = base
                width = min(max(base + drag.translation.width, range.lowerBound), range.upperBound)
            }.onEnded { _ in start = nil }))
            .accessibilityHidden(true)
    }
}

/// A tab for each open buffer: click to show it, × to close it, a dot for unsaved edits.
struct BufferTabs: View {
    let session: DocumentSession
    @Environment(\.orgTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(session.openPaths, id: \.self) { path in
                    tab(path)
                }
            }
        }
        .frame(height: 28)
        .background { Rectangle().fill(theme.color("modeline-background").map(AnyShapeStyle.init) ?? AnyShapeStyle(.bar)) }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(_ path: String) -> some View {
        let current = path == session.path
        return HStack(spacing: 6) {
            Text(session.bufferName(path))
                .lineLimit(1)
                .foregroundStyle(current ? .primary : .secondary)
                .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { session.open(path) }
            Button {
                if path == session.path {
                    if UnsavedChanges.resolve(session) { session.kill(path) }
                } else if UnsavedChanges.resolve(session, paths: [path]) {
                    session.kill(path)
                }
            } label: {
                Image(systemName: session.dirtyPaths.contains(path) ? "circle.fill" : "xmark")
                    .font(.system(size: session.dirtyPaths.contains(path) ? 6 : 9, weight: .semibold))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close \(session.bufferName(path))" + (session.dirtyPaths.contains(path) ? ", unsaved" : ""))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        // A shape, not a color: a color background runs up under the toolbar.
        .background { Rectangle().fill(current ? theme.color("background") ?? Color(nsColor: .textBackgroundColor) : .clear) }
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { session.open(path) }
        .help(path)
    }
}

enum Panel: Identifiable {
    case columns(UUID, ColumnView.View)
    case export(UUID, URL)
    case conflict(UUID)
    case syncCopies(UUID)
    case recovery(UUID)

    var id: UUID {
        switch self {
        case .columns(let id, _), .export(let id, _), .conflict(let id), .syncCopies(let id), .recovery(let id): id
        }
    }
}

struct BlockEditRequest: Identifiable {
    let id = UUID()
    let edit: BlockEdit
}
