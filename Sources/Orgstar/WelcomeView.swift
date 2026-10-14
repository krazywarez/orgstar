import OrgApp
import OrgCore
import SwiftUI

/// The first launch, with no folder added: add a folder or start one, and pick the keys.
struct WelcomeView: View {
    let workspace: WorkspaceModel
    /// Opens the folder picker once the sheet has closed.
    let chooseFolder: () -> Void
    /// Shows the file the sheet made.
    let open: (String) -> Void
    @AppStorage("keymap") private var preset = KeymapPreset.emacs
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    /// iCloud Drive's folder, when iCloud Drive is on for this user.
    static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to orgstar").font(.title2.bold())
            Text("orgstar edits a folder of plain-text org files in place. Add the folder your notes are in, or start a new one. Nothing is copied or moved, and you can add more folders later with File ▸ Add Folder….")
            Picker("Keys", selection: $preset) {
                ForEach(KeymapPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(presetNote).font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Not Now") { dismiss() }
                Spacer()
                if let drive = Self.iCloudDrive {
                    Button("New Folder in iCloud Drive") { start(in: drive.appendingPathComponent("org")) }
                        .help("Makes org/notes.org in iCloud Drive and adds the folder")
                }
                Button("Choose Folder…") {
                    dismiss()
                    chooseFolder()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var presetNote: LocalizedStringKey {
        switch preset {
        case .emacs: "Org's own bindings: C-c C-t cycles TODO, C-c C-s schedules, M-RET makes a heading."
        case .mac: "Standard Mac editing keys, with Org commands on ⌃⌘: ⌃⌘T cycles TODO, ⌃⌘S schedules."
        case .doom: "Modal editing as in Doom Emacs, with SPC as the leader: SPC m t cycles TODO."
        }
    }

    /// Makes `folder` with a notes file in it, adds it, and opens the file.
    private func start(in folder: URL) {
        Task {
            do {
                let file = folder.appendingPathComponent("notes.org")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) {
                    try "* Inbox\n".write(to: file, atomically: true, encoding: .utf8)
                }
                try await workspace.addRoot(folder)
                open(file.standardizedFileURL.path)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
