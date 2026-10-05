import Foundation
import Observation
import OrgCore
import OrgDocument

/// Capture templates from `capture.toml`, and capturing into their targets:
///
/// ```toml
/// [[template]]
/// key = "t"
/// name = "Personal todo"
/// type = "entry"            # entry, item, checkitem or plain
/// file = "todo.org"         # relative to the first folder, or ~/… or /…
/// headline = "Inbox"        # or olp = "Projects/Work"; neither for the end of the file
/// template = "* TODO %?\n%i\n%a"
/// prepend = false
/// ```
@MainActor
public enum CaptureTemplates {
    public static var userFile: URL { UserConfig.file("capture.toml") }

    /// The templates in your Doom configuration.
    public static let defaults = [
        CaptureTemplate(key: "t", name: "Personal todo", target: .headline(file: "todo.org", headline: "Inbox"), template: "* TODO %?\n%i\n%a"),
        CaptureTemplate(key: "n", name: "Personal notes", target: .headline(file: "notes.org", headline: "Inbox"), template: "* %u %?\n%i\n%a"),
    ]

    public static func load(userFile: URL = userFile) -> (templates: [CaptureTemplate], problems: [String]) {
        guard let text = try? String(contentsOf: userFile, encoding: .utf8) else { return (defaults, []) }
        let tables: [TOML.Table]
        do {
            tables = try TOML.parse(text)
        } catch {
            return (defaults, ["capture.toml: \(error)"])
        }
        var templates: [CaptureTemplate] = []
        var problems: [String] = []
        for table in tables where !(table.name.isEmpty && table.values.isEmpty) {
            guard table.name == "template", table.isArrayElement else {
                problems.append("capture.toml line \(table.line): expected [[template]]")
                continue
            }
            guard let key = table.values["key"]?.string, let file = table.values["file"]?.string, let body = table.values["template"]?.string else {
                problems.append("capture.toml line \(table.line): a template needs key, file and template")
                continue
            }
            guard let kind = CaptureTemplate.Kind(rawValue: table.values["type"]?.string ?? "entry") else {
                problems.append("capture.toml line \(table.line): unknown type")
                continue
            }
            let target: CaptureTemplate.Target
            if let headline = table.values["headline"]?.string {
                target = .headline(file: file, headline: headline)
            } else if let olp = table.values["olp"]?.string {
                target = .outline(file: file, path: olp.split(separator: "/").map(String.init))
            } else {
                target = .file(file)
            }
            templates.append(CaptureTemplate(
                key: key, name: table.values["name"]?.string ?? key, kind: kind, target: target, template: body,
                prepend: table.values["prepend"]?.bool ?? false
            ))
        }
        return (templates.isEmpty ? defaults : templates, problems)
    }
}

extension DocumentSession {
    /// Places captured `text` with `template`: through the buffer when the target is open,
    /// otherwise in the file, created if missing, through the save path.
    public func capture(_ text: String, template: CaptureTemplate, root: String?) -> String? {
        let path = Self.resolve(template.target.file, root: root)
        if path != self.path, !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: path))
            } catch {
                return "Can't create \(path): \(error.localizedDescription)"
            }
        }
        switch perform(CapturePlacement(text: text, template: template), path: path, at: 0, expect: nil) {
        case .commit: return nil
        case .failed(let message): return message
        default: return "Can't capture there."
        }
    }

    /// A template's file: absolute, `~/…`, or relative to `root`.
    public static func resolve(_ file: String, root: String?) -> String {
        if file.hasPrefix("/") { return file }
        if file.hasPrefix("~") { return (file as NSString).expandingTildeInPath }
        return ((root ?? FileManager.default.homeDirectoryForCurrentUser.path) as NSString).appendingPathComponent(file)
    }

    /// `%a`: a link to the heading at the caret, as `org-store-link` makes one.
    public func captureAnnotation() -> String {
        guard let path, self.document != nil else { return "" }
        let abbreviated = path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : Substring(path)
        guard let entry = outline.last(where: { $0.start <= caret }) else { return "[[file:\(abbreviated)]]" }
        return "[[file:\(abbreviated)::*\(entry.title)][\(entry.title)]]"
    }
}

/// The edit `Capture.place` makes, as a command so the save path applies it.
struct CapturePlacement: OrgCommand {
    let text: String
    let template: CaptureTemplate
    var id: String { "internal.capture" }
    var title: String { "Capture" }
    func applies(in context: EditContext) -> Bool { true }
    func run(in context: EditContext) -> CommandStep {
        switch Capture.place(text, template: template, in: context.text, settings: context.tree.settings) {
        case .failure(.message(let message)):
            return .failed(message)
        case .success(let new):
            return .commit(EditResult(baseRevision: context.revision, edits: TextEdit.between(context.text, new)))
        }
    }
}
