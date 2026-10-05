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
    /// The editor showing the open file, for menus and the palette.
    var editor: OrgEditor?
    /// The pending key prefix, and what can follow it.
    var pendingKeys: String?
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        return UnsavedChanges.resolve(session) ? .terminateNow : .terminateCancel
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
}

@main
struct OrgstarApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var workspace = Result {
        try WorkspaceModel(directory: WorkspaceModel.defaultDirectory, settings: .with(todoKeywords: Preferences.orgSettings))
    }
    @State private var commands = AppCommands()
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
                ContentView(workspace: model, session: session, commands: commands, scheduler: scheduler)
                    .onAppear {
                        delegate.session = session
                        delegate.commands = commands
                    }
            case .failure(let error):
                ContentUnavailableView("Can't open the index", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            }
        }
        .defaultSize(width: 1280, height: 860)
        Window("Agenda", id: "agenda") {
            if case .success(let model) = workspace {
                AgendaView(workspace: model, session: session, commands: commands, scheduler: scheduler)
            }
        }
        .defaultSize(width: 760, height: 720)
        Window("Capture", id: "capture") {
            if case .success(let model) = workspace {
                CaptureView(workspace: model, session: session, commands: commands)
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
                Button("Save") {
                    if !session.save(), session.conflict != nil { commands.showingConflict = true }
                }
                .keyboardShortcut("s")
                .disabled(session.path == nil || session.isReadOnly)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Notes") { commands.focusSearch = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandGroup(before: .windowList) {
                AgendaMenuItem()
            }
            CommandGroup(after: .newItem) {
                Button("Capture…") { commands.run("app.capture") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .commands {
            CommandMenu("Org") {
                ForEach(EditorCommands.all.filter { $0.id.hasPrefix("org.") }, id: \.id) { command in
                    Button(command.title) { commands.editor?.run(command.id) }
                        .disabled(commands.editor == nil)
                }
            }
        }
        Settings {
            SettingsView()
        }
    }
}

/// Window ▸ Agenda.
struct AgendaMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Agenda") { openWindow(id: "agenda") }
            .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

struct SettingsView: View {
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
    @AppStorage("todoKeywords") private var todoKeywords = Preferences.defaultTodoKeywords
    @AppStorage("agendaSpan") private var agendaSpan = 10
    @AppStorage("agendaStartOffset") private var agendaStartOffset = -3
    @AppStorage("agendaSubfolders") private var agendaSubfolders = false
    @AppStorage("reminders") private var reminders = true
    @AppStorage("reminderLead") private var reminderLead = 12
    @AppStorage("globalCapture") private var globalCapture = true

    var body: some View {
        Form {
            Picker("Save files:", selection: $saveMode) {
                Text("Automatically, when typing stops").tag(SaveMode.automatic)
                Text("Only with File ▸ Save (⌘S)").tag(SaveMode.explicit)
            }
            .pickerStyle(.radioGroup)
            Picker("Keys:", selection: $preset) {
                ForEach(KeymapPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Option as Meta:", selection: $optionAsMeta) {
                Text("Left Option").tag(OptionAsMeta.left.rawValue)
                Text("Right Option").tag(OptionAsMeta.right.rawValue)
                Text("Both").tag(OptionAsMeta([.left, .right]).rawValue)
                Text("Neither").tag(0)
            }
            Text("Your own bindings go in \(KeymapLoader.userFile.path), on top of the preset.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            Picker("Tags:", selection: $tagsColumn) {
                Text("Aligned to end at column 77").tag(-77)
                Text("One space after the title").tag(0)
            }
            Toggle("M-RET adds the new heading after the subtree", isOn: $headingAfterSubtree)
            Toggle("M-RET splits the line at the caret", isOn: $splitLine)
            Toggle("Lists can use letters (a. b. c.)", isOn: $alphabeticalLists)
            Stepper("M-q fills to column \(fillColumn)", value: $fillColumn, in: 40...200)
            Toggle("Emacs hides emphasis markers (org-hide-emphasis-markers)", isOn: $hiddenMarkers)
            Toggle("Emacs shows entities as characters (org-pretty-entities)", isOn: $prettyEntities)
            Text("Tags, tables and M-q measure text as your Emacs displays it, so both write the same file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Default TODO keywords:", text: $todoKeywords)
            Text("For files without #+TODO, in #+TODO syntax. Takes effect when Orgstar restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Stepper("Agenda shows \(agendaSpan) days", value: $agendaSpan, in: 1...31)
            Stepper(agendaStartOffset == 0 ? "Agenda starts today" : "Agenda starts \(-agendaStartOffset) days before today", value: $agendaStartOffset, in: -14...0)
            Toggle("Agenda includes files in subfolders", isOn: $agendaSubfolders)
            Toggle("Notify before timed agenda entries", isOn: $reminders)
            Stepper("\(reminderLead) minutes before (APPT_WARNTIME overrides)", value: $reminderLead, in: 0...120)
                .disabled(!reminders)
            Toggle("⌃⌥Space opens Capture from any app", isOn: $globalCapture)
            Text("Templates go in \(CaptureTemplates.userFile.path).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(width: 480)
    }
}
