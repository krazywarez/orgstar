import AppKit
import OrgApp
import OrgCore
import OrgEditorAppKit
import SwiftUI

/// Window-level requests the menu bar makes.
@MainActor
@Observable
final class AppCommands {
    var showingQuickOpen = false
    var showingFolderPicker = false
    var focusSearch = false
    var showingConflict = false
    var showingPalette = false
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    var session: DocumentSession?

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
    @State private var session: DocumentSession = {
        let session = DocumentSession()
        session.defaults = Preferences.orgSettings
        return session
    }()

    var body: some Scene {
        Window("Orgstar", id: "main") {
            switch workspace {
            case .success(let model):
                ContentView(workspace: model, session: session, commands: commands)
                    .onAppear { delegate.session = session }
            case .failure(let error):
                ContentUnavailableView("Can't open the index", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            }
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { commands.showingFolderPicker = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Quick Open…") { commands.showingQuickOpen = true }
                    .keyboardShortcut("p")
                Button("Command Palette…") { commands.showingPalette = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
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

struct SettingsView: View {
    @AppStorage("saveMode") private var saveMode = SaveMode.automatic
    @AppStorage("keymap") private var preset = KeymapPreset.emacs
    @AppStorage("optionAsMeta") private var optionAsMeta = OptionAsMeta.left.rawValue
    @AppStorage("tagsColumn") private var tagsColumn = -77
    @AppStorage("headingAfterSubtree") private var headingAfterSubtree = true
    @AppStorage("splitLine") private var splitLine = false
    @AppStorage("alphabeticalLists") private var alphabeticalLists = true
    @AppStorage("fillColumn") private var fillColumn = 80
    @AppStorage("todoKeywords") private var todoKeywords = Preferences.defaultTodoKeywords

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
            TextField("Default TODO keywords:", text: $todoKeywords)
            Text("For files without #+TODO, in #+TODO syntax. Takes effect when Orgstar restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 480)
    }
}
