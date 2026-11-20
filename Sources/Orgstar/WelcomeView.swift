import OrgApp
import OrgCore
import OrgWorkspace
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

    /// iCloud Drive's folder in the real home folder.
    static let iCloudDriveFolder = URL(fileURLWithPath: OrgPaths.home).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    /// iCloud Drive's folder, when iCloud Drive is on for this user.
    static var iCloudDrive: URL? {
        FileManager.default.fileExists(atPath: iCloudDriveFolder.path) ? iCloudDriveFolder : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to orgstar").font(.title2.bold())
            Text("orgstar edits a folder of plain-text org files in place. Add the folder your notes are in, or start a new one. Nothing is copied or moved, and you can add more folders later with File ▸ Add Folder….")
            Picker("Keys", selection: $preset) {
                ForEach(KeymapPreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(presetNote).font(.callout).foregroundStyle(.secondary)
            #if APPSTORE
            ForEach(workspace.unresolvedRoots, id: \.path) { root in
                HStack {
                    Label(OrgPaths.abbreviatingWithTilde(root.path), systemImage: "exclamationmark.triangle")
                        .help("orgstar can't open this folder")
                    Spacer()
                    Button("Grant Access…") { GrantAccess.regrant(root, workspace: workspace) }
                }
            }
            #endif
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Not Now") { dismiss() }
                Spacer()
                #if APPSTORE
                // The sandbox reaches iCloud Drive only through a folder chosen there.
                Button("New Folder in iCloud Drive…") { chooseInICloudDrive() }
                    .help("Makes notes.org in a folder you choose or make in iCloud Drive and adds the folder")
                #else
                if let drive = Self.iCloudDrive {
                    Button("New Folder in iCloud Drive") { start(in: drive.appendingPathComponent("org")) }
                        .help("Makes org/notes.org in iCloud Drive and adds the folder")
                }
                #endif
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

    #if APPSTORE
    /// An open panel in iCloud Drive; the folder chosen or made there becomes the notes folder.
    private func chooseInICloudDrive() {
        let message = String(localized: "Choose or make the folder for your notes in iCloud Drive.", comment: "Open panel on the welcome sheet")
        guard let folder = GrantAccess.choose(at: Self.iCloudDriveFolder, message: message, prompt: String(localized: "Use Folder", comment: "Open panel button on the welcome sheet")) else { return }
        start(in: folder)
    }
    #endif

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
