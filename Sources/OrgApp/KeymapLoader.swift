import Foundation
import OrgCore

@MainActor
public enum KeymapLoader {
    /// `<data dir>/keymap.toml`.
    public static var userFile: URL { WorkspaceModel.defaultDirectory.appendingPathComponent("keymap.toml") }

    /// The preset with the user's file on top, and the problems found in the file. A missing
    /// file adds nothing; a file that isn't valid TOML adds nothing and is reported.
    public static func load(_ preset: KeymapPreset, userFile: URL = userFile) -> (keymap: Keymap, problems: [String]) {
        guard let text = try? String(contentsOf: userFile, encoding: .utf8) else { return (preset.keymap, []) }
        var problems: [String] = []
        do {
            let user = try Keymap(toml: text, problems: &problems)
            return (.layered([preset.keymap, user]), problems)
        } catch {
            return (preset.keymap, ["\(error)"])
        }
    }
}
