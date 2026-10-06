import AppKit
import OrgApp
import OrgCore

/// Follows a link, handing addresses and files Orgstar doesn't edit to macOS.
@MainActor
enum LinkOpener {
    /// Returns a message when the link can't be followed.
    static func open(_ link: OrgLink, session: DocumentSession, workspace: WorkspaceModel) -> String? {
        switch session.follow(link, workspace: workspace, isText: FileTypes.isText) {
        case .shown: return nil
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            return nil
        case .message(let message): return message
        }
    }
}
