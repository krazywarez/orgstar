#if APPSTORE
import AppKit
import OrgApp
import OrgCore
import OrgWorkspace

/// Access to folders outside the sidebar's folders, which the sandbox keeps orgstar out of
/// until they're chosen in an open panel.
@MainActor
enum GrantAccess {
    enum Answer {
        case granted, alternative, canceled
    }

    /// Says orgstar can't reach `folder` and offers an open panel at it, plus `alternative`
    /// when given. A folder chosen in the panel is kept as a grant; `granted` once it covers
    /// `folder`.
    static func ask(_ folder: URL, workspace: WorkspaceModel, alternative: String? = nil) -> Answer {
        let alert = NSAlert()
        let name = OrgPaths.abbreviatingWithTilde(folder.path)
        alert.messageText = String(localized: "orgstar can't reach \(name).", comment: "Alert for a folder outside the sidebar's folders")
        alert.informativeText = String(localized: "It isn't in one of your folders. Grant access to it to continue.", comment: "Alert for a folder outside the sidebar's folders")
        alert.addButton(withTitle: String(localized: "Grant Access…", comment: "Button that opens a panel to give orgstar access to a folder"))
        if let alternative { alert.addButton(withTitle: alternative) }
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertSecondButtonReturn where alternative != nil: return .alternative
        default: return .canceled
        }
        guard let url = choose(at: folder, message: String(localized: "Choose \(name) or a folder that contains it.", comment: "Open panel for giving orgstar access to a folder"),
                               prompt: String(localized: "Grant Access", comment: "Open panel button that gives orgstar access to a folder")) else { return .canceled }
        FolderGrants.shared.add(url)
        return workspace.foldersToGrant(for: [folder.path], directories: true).isEmpty ? .granted : .canceled
    }

    /// An open panel at `location`, for a folder, or a file too with `files`. Hidden files show
    /// with `hidden`, for dot folders such as `~/.config`.
    static func choose(at location: URL, message: String, prompt: String, files: Bool = false, hidden: Bool = false) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = files
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = hidden
        panel.directoryURL = location
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks again for `root`, a sidebar folder that doesn't resolve, with an open panel at where
    /// it was, and puts the folder chosen in its place.
    static func regrant(_ root: WorkspaceRoot, workspace: WorkspaceModel) {
        let name = OrgPaths.abbreviatingWithTilde(root.path)
        guard let url = choose(at: URL(fileURLWithPath: root.path),
                               message: String(localized: "Choose \(name) to give orgstar access to it again.", comment: "Open panel for a sidebar folder orgstar can't open"),
                               prompt: String(localized: "Grant Access", comment: "Open panel button that gives orgstar access to a folder")) else { return }
        Task {
            do { try await workspace.regrant(root, with: url) } catch { workspace.lastError = error.localizedDescription }
        }
    }

    /// Asks for each folder `paths` need, in turn. Whether all of them can now be reached.
    static func reach(_ paths: [String], directories: Bool = false, workspace: WorkspaceModel) -> Bool {
        for folder in workspace.foldersToGrant(for: paths, directories: directories) {
            // An earlier grant may cover this one.
            guard !workspace.foldersToGrant(for: [folder.path], directories: true).isEmpty else { continue }
            guard ask(folder, workspace: workspace) == .granted else { return false }
        }
        return true
    }
}
#endif
