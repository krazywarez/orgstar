import OrgApp
import SwiftUI

/// Window-level requests the menu bar makes.
@MainActor
@Observable
final class AppCommands {
    var showingQuickOpen = false
    var showingFolderPicker = false
    var focusSearch = false
}

@main
struct OrgstarApp: App {
    @State private var workspace = Result { try WorkspaceModel(directory: WorkspaceModel.defaultDirectory) }
    @State private var commands = AppCommands()

    var body: some Scene {
        Window("Orgstar", id: "main") {
            switch workspace {
            case .success(let model):
                ContentView(workspace: model, commands: commands)
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
            }
            CommandGroup(after: .textEditing) {
                Button("Search Notes") { commands.focusSearch = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}
