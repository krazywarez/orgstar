import AppKit
import OrgApp
import OrgCore

/// Follows a link, handing addresses and files Orgstar doesn't edit to macOS.
@MainActor
enum LinkOpener {
    /// Returns a message when the link can't be followed.
    /// `ask` picks among a query link's matches.
    static func open(_ link: OrgLink, session: DocumentSession, workspace: WorkspaceModel, ask: @escaping (Prompt, @escaping (String?) -> Void) -> Void) -> String? {
        switch session.follow(link, workspace: workspace, isText: FileTypes.isText) {
        case .shown: return nil
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            return nil
        case .message(let message): return message
        case .choose(let prompt, let paths):
            let labels = paths.map { ($0 as NSString).lastPathComponent }
            ask(Prompt(key: "file", message: prompt, choices: labels)) { answer in
                guard let answer, let index = labels.firstIndex(of: answer) else { return }
                _ = open(OrgLink(type: "file", path: paths[index], raw: "file:" + paths[index]), session: session, workspace: workspace, ask: ask)
            }
            return nil
        }
    }
}
