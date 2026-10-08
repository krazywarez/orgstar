import AppKit
import OrgApp
import OrgCore
import OrgEditorAppKit
import SwiftUI
import UserNotifications

/// Window-level requests the menu bar makes.
@MainActor
@Observable
final class AppCommands {
    var showingQuickOpen = false
    var showingFolderPicker = false
    var focusSearch = false
    var showingConflict = false
    var showingPalette = false
    /// A location another window asked the main window to show.
    private(set) var jumpRequest: (path: String, offset: Int, id: Int)?
    private var jumpID = 0
    /// Days the agenda window should show, from a followed timestamp.
    var agendaRequest: (start: Int, days: Int)?
    /// The editor showing the open file, for menus and the palette.
    var editor: OrgEditor?
    /// The pending key prefix, and what can follow it.
    var pendingKeys: String?
    /// The editor's evil state in the Doom preset.
    var editorState: String?
    /// The keymap in use, for showing keys in menus and the palette.
    var keymap = KeymapPreset.emacs.keymap
    var modal = false
    /// `org-stored-links`, most recent first; kept for the session, as in Emacs.
    var storedLinks: [StoredLink] = []

    /// `org-link--add-to-stored-links`: puts `link` first and says what happened.
    func storeLink(_ link: StoredLink) {
        if storedLinks.first == link {
            show("This link has already been stored")
        } else {
            let moved = storedLinks.contains(link)
            storedLinks.removeAll { $0 == link }
            storedLinks.insert(link, at: 0)
            show((moved ? "Link moved to front: " : "Stored: ") + (link.description ?? link.link))
        }
    }

    /// The keys that run `command`, as menus and the palette show them.
    func keyLabel(for command: String) -> String? {
        let labels = keymap.keyLabels(for: command, modes: modal ? ["normal", "insert"] : [nil])
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// The editor's selection, for the modeline.
    var selection = NSRange(location: 0, length: 0)
    var keyHints: [KeyHint] = []
    /// A question a command asked, answered in the echo area.
    private(set) var prompt: PromptRequest?
    /// The last message from a command or the keymap, cleared after a few seconds.
    private(set) var message: String?
    private var messageID = 0

    func ask(_ prompt: Prompt, reply: @escaping (String?) -> Void) {
        self.prompt = PromptRequest(prompt: prompt, reply: reply)
    }

    /// Ends the prompt with an answer, or nil to cancel, and gives the editor the keys back.
    func answer(_ text: String?) {
        guard let request = prompt else { return }
        prompt = nil
        if let textView = editor?.textView { textView.window?.makeFirstResponder(textView) }
        request.reply(text)
    }

    /// An app command from a menu, run by the main window.
    private(set) var runRequest: (id: String, serial: Int)?
    private var runSerial = 0

    func run(_ id: String) {
        runSerial += 1
        runRequest = (id, runSerial)
    }

    /// An org-protocol capture waiting for the capture window: the template key and the link
    /// properties for its escapes.
    var captureRequest: (template: String?, properties: [String: String], serial: Int)?
    private var captureSerial = 0

    /// `org-protocol://capture` and `store-link`.
    func handle(protocolURL url: String) {
        switch OrgProtocol.parse(url) {
        case .capture(let template, let properties):
            captureSerial += 1
            captureRequest = (template, properties, captureSerial)
            run("app.capture")
        case .storeLink(let link, let title):
            storeLink(StoredLink(link: link, description: title))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        case nil:
            show("Orgstar handles org-protocol capture and store-link")
        }
    }

    func jump(path: String, offset: Int) {
        jumpID += 1
        jumpRequest = (path, offset, jumpID)
    }

    func show(_ text: String) {
        messageID += 1
        let id = messageID
        message = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if messageID == id { message = nil }
        }
    }
}

struct PromptRequest: Identifiable {
    let id = UUID()
    let prompt: Prompt
    let reply: (String?) -> Void
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var session: DocumentSession?
    var commands: AppCommands?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SystemReminderCenter.isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    /// `:session` interpreters end with the app.
    func applicationWillTerminate(_ notification: Notification) {
        BabelSessions.shared.stopAll()
    }

    /// Reminders show while Orgstar is in front too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Clicking a reminder shows its entry.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let path = info["path"] as? String, let offset = info["offset"] as? Int else { return }
        await MainActor.run {
            NSApp.activate()
            commands?.jump(path: path, offset: offset)
        }
    }

    /// Files opened from Finder, `open`, or a drop on the Dock icon: each opens as a buffer.
    /// Ones that arrive before the window is ready wait for it (`pendingOpens`).
    static var pendingOpens: [String] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.filter(\.isFileURL).map(\.path)
        let links = urls.filter { $0.scheme == "org-protocol" }.map(\.absoluteString)
        guard let commands, let session else {
            Self.pendingOpens += paths
            Self.pendingLinks += links
            return
        }
        NSApp.activate()
        for path in paths { session.open(path) }
        for link in links { commands.handle(protocolURL: link) }
    }

    /// org-protocol links that arrive before the window is ready.
    static var pendingLinks: [String] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        BufferRestore.save(session)
        return UnsavedChanges.resolve(session, paths: session.openPaths) ? .terminateNow : .terminateCancel
    }
}

/// Unsaved edits when leaving a file or quitting.
@MainActor
enum UnsavedChanges {
    /// Whether the open file can be left: saved in automatic mode, or as the user chooses in
    /// explicit mode. A save that fails or conflicts keeps the file open.
    static func resolve(_ session: DocumentSession) -> Bool {
        guard session.isDirty else { return true }
        if session.saveMode == .automatic { return session.save() }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.path.map { ($0 as NSString).lastPathComponent } ?? "this file")?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return session.save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// Whether the buffers of `paths` can be closed: saved in automatic mode, or as the user
    /// chooses for all of them in explicit mode.
    static func resolve(_ session: DocumentSession, paths: [String]) -> Bool {
        let dirty = paths.filter(session.dirtyPaths.contains)
        guard !dirty.isEmpty else { return true }
        if session.saveMode == .automatic { return dirty.map(session.save).allSatisfy { $0 } }
        if dirty == [session.path] { return resolve(session) }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(dirty.count) files?"
        alert.informativeText = dirty.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return dirty.map(session.save).allSatisfy { $0 }
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
}

/// The open buffers, their order and carets, kept for the next launch.
@MainActor
enum BufferRestore {
    private static let key = "openBuffers"

    struct State: Codable {
        var paths: [String]
        var current: String?
        var carets: [String: Int]
    }

    static func save(_ session: DocumentSession, defaults: UserDefaults = .standard) {
        var carets: [String: Int] = [:]
        for path in session.openPaths { carets[path] = session.caret(of: path) }
        let state = State(paths: session.openPaths, current: session.path, carets: carets)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }

    /// Opens the buffers that were open, in order, and returns the carets to show them at.
    static func restore(_ session: DocumentSession, defaults: UserDefaults = .standard) -> [String: Int] {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(State.self, from: data) else { return [:] }
        let existing = state.paths.filter { FileManager.default.fileExists(atPath: $0) }
        for path in existing { session.open(path) }
        if let current = state.current, existing.contains(current) { session.open(current) }
        return state.carets
    }
}

@main
struct OrgstarApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var workspace = Result {
        try WorkspaceModel(directory: WorkspaceModel.defaultDirectory, settings: .with(todoKeywords: Preferences.orgSettings))
    }
    @State private var commands = AppCommands()
    @State private var clock = ClockModel()
    @State private var scheduler = SystemReminderCenter.isAvailable ? ReminderScheduler(center: SystemReminderCenter()) : nil
    @State private var session: DocumentSession = {
        let session = DocumentSession()
        session.defaults = Preferences.orgSettings
        return session
    }()

    var body: some Scene {
        Window("Orgstar", id: "main") {
            switch workspace {
            case .success(let model):
                ContentView(workspace: model, session: session, commands: commands, scheduler: scheduler, clock: clock)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
                    .onAppear {
                        delegate.session = session
                        delegate.commands = commands
                        CaptureIntent.environment = (model, session, clock, commands)
                    }
            case .failure(let error):
                ContentUnavailableView("Can't open the index", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            }
        }
        .defaultSize(width: 1280, height: 860)
        Window("Agenda", id: "agenda") {
            if case .success(let model) = workspace {
                AgendaView(workspace: model, session: session, commands: commands, scheduler: scheduler, clock: clock)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
            }
        }
        .defaultSize(width: 760, height: 720)
        Window("Board", id: "board") {
            if case .success(let model) = workspace {
                BoardView(workspace: model, session: session, commands: commands)
                    .environment(\.orgTheme, ConfigSync.shared.theme)
            }
        }
        .defaultSize(width: 1100, height: 700)
        Window("Clock Report", id: "clock-report") {
            if case .success(let model) = workspace {
                ClockReportView(workspace: model)
            }
        }
        .defaultSize(width: 860, height: 560)
        Window("Capture", id: "capture") {
            if case .success(let model) = workspace {
                CaptureView(workspace: model, session: session, commands: commands, clock: clock)
            }
        }
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { commands.showingFolderPicker = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Quick Open…") { commands.showingQuickOpen = true }
                    .keyboardShortcut("p")
                Button("Command Palette…") { commands.showingPalette = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Menu("Export") {
                    ForEach(EditorCommands.all.filter { $0.id.hasPrefix("app.export.") }, id: \.id) { command in
                        Button(command.title) { commands.run(command.id) }
                    }
                }
                .disabled(session.path == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Buffer") {
                    // ⌘W closes the buffer in the main window, and other windows themselves.
                    if let key = NSApp.keyWindow, key.identifier?.rawValue.contains("main") != true {
                        key.performClose(nil)
                    } else {
                        commands.run("app.buffer.kill")
                    }
                }
                .keyboardShortcut("w")
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Save") {
                    if !session.save(), session.conflict != nil { commands.showingConflict = true }
                }
                .keyboardShortcut("s")
                .disabled(session.path == nil || session.isReadOnly)
                Button("Save All") { commands.run("app.save-all") }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(session.dirtyPaths.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button("Show or Hide Outline") { commands.run("app.toggle-outline") }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Show or Hide Backlinks") { commands.run("app.toggle-backlinks") }
                Button("Show or Hide Columns and Clock") { commands.run("app.toggle-inspector") }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                MarkupToggle()
                Button("Truncate or Wrap Long Lines") { commands.run("editor.toggle-truncate-lines") }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                FindMenu(commands: commands)
            }
            CommandGroup(after: .textEditing) {
                Button("Cancel Running Block") { commands.run("app.babel.cancel") }
                    .keyboardShortcut(".")
                    .disabled(!session.isRunningBabel)
                Button("Search Notes") { commands.focusSearch = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowList) {
                AgendaMenuItem()
                Divider()
                Button("Switch to Buffer…") { commands.run("app.buffer.switch") }
                Button("Next Buffer") { commands.run("app.buffer.next") }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Buffer") { commands.run("app.buffer.previous") }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
            }
            CommandGroup(after: .newItem) {
                Button("Capture…") { commands.run("app.capture") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .commands {
            CommandMenu("Org") {
                OrgMenuItems(commands: commands)
            }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Edit Config File") { commands.jump(path: UserConfig.configFile.path, offset: 0) }
                    .keyboardShortcut(",", modifiers: [.command, .option])
            }
        }
        Settings {
            SettingsView(commands: commands, workspace: try? workspace.get())
        }
    }
}

/// The Org menu: every org command, with the keys that run it in the current keymap.
struct OrgMenuItems: View {
    let commands: AppCommands

    var body: some View {
        ForEach(EditorCommands.all.filter { $0.id.hasPrefix("org.") }, id: \.id) { command in
            Button {
                commands.editor?.run(command.id)
            } label: {
                Text(command.title)
                if let keys = commands.keyLabel(for: command.id) { Text(keys) }
            }
            .disabled(commands.editor == nil)
        }
    }
}

/// View ▸ Show Markup (link brackets and targets, emphasis markers) and Show Line Numbers.
struct MarkupToggle: View {
    @AppStorage("showTabBar") private var showTabBar = false
    @AppStorage("showMarkup") private var showMarkup = false
    @AppStorage("showLineNumbers") private var showLineNumbers = true

    var body: some View {
        Toggle("Show Markup", isOn: $showMarkup)
            .keyboardShortcut("m", modifiers: [.command, .shift])
        Toggle("Show Line Numbers", isOn: $showLineNumbers)
            .keyboardShortcut("l", modifiers: [.command, .shift])
        Toggle("Show Tab Bar", isOn: $showTabBar)
    }
}

/// Edit ▸ Find: the editor's find bar.
struct FindMenu: View {
    let commands: AppCommands

    var body: some View {
        Menu("Find") {
            item("Find…", "edit.find", "f")
            item("Find and Replace…", "edit.replace", "f", [.command, .option])
            item("Find Next", "edit.find-next", "g")
            item("Find Previous", "edit.find-previous", "g", [.command, .shift])
            item("Use Selection for Find", "edit.use-selection-for-find", "e")
        }
    }

    private func item(_ title: String, _ id: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { commands.editor?.run(id) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(commands.editor == nil)
    }
}

/// Window ▸ Agenda.
struct AgendaMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Agenda") { openWindow(id: "agenda") }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        Button("Board") { openWindow(id: "board") }
            .keyboardShortcut("b", modifiers: [.command, .shift])
    }
}

struct SettingsView: View {
    let commands: AppCommands
    let workspace: WorkspaceModel?
    @State private var importing = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage("saveMode") private var saveMode = SaveMode.automatic
    @AppStorage("keymap") private var preset = KeymapPreset.emacs
    @AppStorage("optionAsMeta") private var optionAsMeta = OptionAsMeta.left.rawValue
    @AppStorage("tagsColumn") private var tagsColumn = -77
    @AppStorage("headingAfterSubtree") private var headingAfterSubtree = true
    @AppStorage("splitLine") private var splitLine = false
    @AppStorage("alphabeticalLists") private var alphabeticalLists = true
    @AppStorage("fillColumn") private var fillColumn = 80
    @AppStorage("hiddenMarkers") private var hiddenMarkers = true
    @AppStorage("prettyEntities") private var prettyEntities = true
    @AppStorage("startupTruncated") private var startupTruncated = false
    @AppStorage("todoKeywords") private var todoKeywords = Preferences.defaultTodoKeywords
    @AppStorage("agendaSpan") private var agendaSpan = 10
    @AppStorage("agendaStartOffset") private var agendaStartOffset = -3
    @AppStorage("agendaSubfolders") private var agendaSubfolders = false
    @AppStorage("reminders") private var reminders = true
    @AppStorage("reminderLead") private var reminderLead = 12
    @AppStorage("globalCapture") private var globalCapture = true
    @AppStorage("settingsTab") private var tab = "general"
    @AppStorage("showHiddenFiles") private var showHiddenFiles = true
    @AppStorage("themeFont") private var themeFont = ""
    @AppStorage("themeFontSize") private var themeFontSize = 13
    @AppStorage("themeLineSpacing") private var themeLineSpacing = 2
    @AppStorage("themeHeadingStep") private var themeHeadingStep = 1

    /// Installed monospaced font families.
    private static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)?.isFixedPitch == true
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { general }
            Tab("Editing", systemImage: "text.alignleft", value: "editing") { editing }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") { appearance }
            Tab("Agenda", systemImage: "calendar", value: "agenda") { agenda }
            Tab("Capture", systemImage: "tray.and.arrow.down", value: "capture") { capture }
        }
        .frame(width: 600)
    }

    private func editConfig() {
        ConfigSync.shared.start()
        openWindow(id: "main")
        commands.jump(path: UserConfig.configFile.path, offset: 0)
    }

    private var general: some View {
        Form {
            Section {
                LabeledContent("config.toml") {
                    HStack {
                        Button("Edit in Orgstar") { editConfig() }
                        Button("Open with Default App") { NSWorkspace.shared.open(UserConfig.configFile) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([UserConfig.configFile]) }
                    }
                }
                LabeledContent("Emacs") {
                    Button("Import from Emacs…") { importing = true }
                }
            } footer: {
                Text("Every setting here is also in \(UserConfig.configFile.path), which you can edit, share or keep with your dotfiles. Changes in either place show up in the other.")
                    .settingsFooter()
            }
            Section {
                Picker("Save files", selection: $saveMode) {
                    Text("Automatically, when typing stops").tag(SaveMode.automatic)
                    Text("Only with File ▸ Save (⌘S)").tag(SaveMode.explicit)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Picker("Keys", selection: $preset) {
                    ForEach(KeymapPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show hidden files and folders", isOn: $showHiddenFiles)
                Picker("Option as Meta", selection: $optionAsMeta) {
                    Text("Left Option").tag(OptionAsMeta.left.rawValue)
                    Text("Right Option").tag(OptionAsMeta.right.rawValue)
                    Text("Both").tag(OptionAsMeta([.left, .right]).rawValue)
                    Text("Neither").tag(0)
                }
            } footer: {
                Text("Your own bindings go in \(KeymapLoader.userFile.path), on top of the preset.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 330)
        .sheet(isPresented: $importing) { EmacsImportView(workspace: workspace) }
    }

    private var editing: some View {
        Form {
            Section {
                Picker("Tags", selection: $tagsColumn) {
                    Text("Aligned to end at column 77").tag(-77)
                    Text("One space after the title").tag(0)
                }
                Toggle("M-RET adds the new heading after the subtree", isOn: $headingAfterSubtree)
                Toggle("M-RET splits the line at the caret", isOn: $splitLine)
                Toggle("Lists can use letters (a. b. c.)", isOn: $alphabeticalLists)
                Stepper("M-q fills to column \(fillColumn)", value: $fillColumn, in: 40...200)
            }
            Section {
                Toggle("Long lines run off the edge instead of wrapping (org-startup-truncated)", isOn: $startupTruncated)
            } footer: {
                Text("Applies to files as they open. View ▸ Truncate or Wrap Long Lines switches the current file.")
                    .settingsFooter()
            }
            Section {
                Toggle("Emacs hides emphasis markers (org-hide-emphasis-markers)", isOn: $hiddenMarkers)
                Toggle("Emacs shows entities as characters (org-pretty-entities)", isOn: $prettyEntities)
            } footer: {
                Text("Tags, tables and M-q measure text as your Emacs displays it, so both write the same file.")
                    .settingsFooter()
            }
            Section {
                TextField("Default TODO keywords", text: $todoKeywords, axis: .vertical)
            } footer: {
                Text("For files without #+TODO, in #+TODO syntax, one sequence per line. Takes effect when Orgstar restarts.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }

    private var appearance: some View {
        Form {
            Section {
                Picker("Font", selection: $themeFont) {
                    Text("System monospaced").tag("")
                    Divider()
                    ForEach(Self.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                    if !themeFont.isEmpty, !Self.monospacedFamilies.contains(themeFont) { Text(themeFont).tag(themeFont) }
                }
                Stepper("Size: \(themeFontSize) pt", value: $themeFontSize, in: 8...36)
                Stepper("Line spacing: \(themeLineSpacing) pt", value: $themeLineSpacing, in: 0...16)
                Stepper("Headings grow by \(themeHeadingStep) pt a level", value: $themeHeadingStep, in: 0...8)
            } footer: {
                Text("Tags and tables line up in columns, so a monospaced font keeps them straight.")
                    .settingsFooter()
            }
            Section {
                LabeledContent("Colors") {
                    HStack {
                        Button("Edit in config.toml") { editConfig() }
                        Button("Show Default Theme") {
                            openWindow(id: "main")
                            commands.jump(path: UserConfig.directory.appendingPathComponent("default-theme.toml").path, offset: 0)
                        }
                    }
                }
            } footer: {
                Text("Set colors under [theme] (both appearances), [theme.light] or [theme.dark] in config.toml, and TODO keyword colors under [theme.todo]. default-theme.toml lists every color with the default theme's values.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }

    private var agenda: some View {
        Form {
            Section {
                Stepper("Agenda shows \(agendaSpan) days", value: $agendaSpan, in: 1...366)
                Stepper(agendaStartOffset == 0 ? "Agenda starts today" : "Agenda starts \(-agendaStartOffset) days before today", value: $agendaStartOffset, in: -14...0)
                Toggle("Include files in subfolders", isOn: $agendaSubfolders)
            }
            Section {
                Toggle("Notify before timed agenda entries", isOn: $reminders)
                Stepper("\(reminderLead) minutes before", value: $reminderLead, in: 0...120)
                    .disabled(!reminders)
            } footer: {
                Text("An entry's APPT_WARNTIME property overrides the lead time.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 290)
    }

    private var capture: some View {
        Form {
            Section {
                Toggle("⌃⌥Space opens Capture from any app", isOn: $globalCapture)
            } footer: {
                Text("Templates go in \(CaptureTemplates.userFile.path).")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(height: 160)
    }
}

private extension Text {
    func settingsFooter() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
