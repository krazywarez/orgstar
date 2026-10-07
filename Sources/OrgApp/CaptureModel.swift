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
/// type = "entry"            # entry, item, checkitem, plain or table-line
/// file = "todo.org"         # relative to the first folder, or ~/… or /…
/// headline = "Inbox"        # or olp = "Projects/Work"; neither for the end of the file
/// template = "* TODO %?\n%i\n%a"
/// prepend = false
/// ```
///
/// Other targets: `datetree = true` (under `olp` if given; `tree-type` "day", "week" or
/// "month"), `id = "…"` without `file`, `clock = true` without `file`. Other properties, as
/// in `org-capture-templates`: `immediate-finish`, `empty-lines`, `empty-lines-before`,
/// `empty-lines-after`, `jump-to-captured`, `clock-in`, `clock-keep`, `clock-resume`,
/// `table-line-pos`.
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
            let values = table.values
            let fileless = values["id"]?.string != nil || values["clock"]?.bool == true
            guard let key = values["key"]?.string, let body = values["template"]?.string, let file = values["file"]?.string ?? (fileless ? "" : nil) else {
                problems.append("capture.toml line \(table.line): a template needs key, file and template")
                continue
            }
            guard let kind = CaptureTemplate.Kind(rawValue: table.values["type"]?.string ?? "entry") else {
                problems.append("capture.toml line \(table.line): unknown type")
                continue
            }
            let olp = values["olp"]?.string.map { $0.split(separator: "/").map(String.init) }
            let target: CaptureTemplate.Target
            if let id = values["id"]?.string {
                target = .id(id)
            } else if values["clock"]?.bool == true {
                target = .clock
            } else if values["datetree"]?.bool == true {
                guard let tree = CaptureTemplate.TreeType(rawValue: values["tree-type"]?.string ?? "day") else {
                    problems.append("capture.toml line \(table.line): tree-type is day, week or month")
                    continue
                }
                target = .datetree(file: file, path: olp ?? [], tree: tree)
            } else if let headline = values["headline"]?.string {
                target = .headline(file: file, headline: headline)
            } else if let olp {
                target = .outline(file: file, path: olp)
            } else {
                target = .file(file)
            }
            func flag(_ name: String) -> Bool { values[name]?.bool ?? false }
            func lines(_ name: String) -> Int? { values[name]?.integer }
            let options = CaptureTemplate.Options(
                prepend: flag("prepend"), immediateFinish: flag("immediate-finish"), emptyLines: lines("empty-lines"),
                emptyLinesBefore: lines("empty-lines-before"), emptyLinesAfter: lines("empty-lines-after"),
                jumpToCaptured: flag("jump-to-captured"), clockIn: flag("clock-in"), clockKeep: flag("clock-keep"), clockResume: flag("clock-resume"),
                tableLinePos: values["table-line-pos"]?.string
            )
            templates.append(CaptureTemplate(key: key, name: values["name"]?.string ?? key, kind: kind, target: target, template: body, options: options))
        }
        return (templates.isEmpty ? defaults : templates, problems)
    }
}

extension DocumentSession {
    /// Places captured `text` with `template`: through the buffer when the target is open,
    /// otherwise in the file, created if missing, through the save path. `id` and `clock`
    /// targets must be resolved first (`file` names the ID's file). Returns the file and where
    /// the entry starts.
    public func capture(_ text: String, template: CaptureTemplate, root: String?, file: String? = nil, now: Date = Date()) -> Result<(path: String, offset: Int), CaptureError> {
        let path = file ?? Self.resolve(template.target.file, root: root)
        if !isOpen(path), !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: path))
            } catch {
                return .failure(CaptureError(message: "Can't create \(path): \(error.localizedDescription)"))
            }
        }
        switch perform(CapturePlacement(text: text, template: template), path: path, at: 0, expect: nil, now: now) {
        case .commit(let result): return .success((path, result.selection?.first?.lowerBound ?? 0))
        case .failed(let message): return .failure(CaptureError(message: message))
        default: return .failure(CaptureError(message: "Can't capture there."))
        }
    }

    /// A template's file: absolute, `~/…`, or relative to `root`.
    public static func resolve(_ file: String, root: String?) -> String {
        if file.hasPrefix("/") { return file }
        if file.hasPrefix("~") { return (file as NSString).expandingTildeInPath }
        return ((root ?? NSHomeDirectory()) as NSString).appendingPathComponent(file)
    }

    /// `%a`: a link to the heading at the caret, as `org-store-link` makes one.
    public func captureAnnotation() -> String {
        guard let path, self.document != nil else { return "" }
        let abbreviated = path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : Substring(path)
        guard let entry = outline.last(where: { $0.start <= caret }) else { return "[[file:\(abbreviated)]]" }
        return "[[file:\(abbreviated)::*\(entry.title)][\(entry.title)]]"
    }
}

public struct CaptureError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// The edit `Capture.place` makes, as a command so the save path applies it. The selection
/// it leaves is the captured entry's start.
struct CapturePlacement: OrgCommand {
    let text: String
    let template: CaptureTemplate
    var id: String { "internal.capture" }
    var title: String { "Capture" }
    func applies(in context: EditContext) -> Bool { true }
    func run(in context: EditContext) -> CommandStep {
        switch Capture.placement(text, template: template, in: context.text, settings: context.tree.settings, now: context.now, calendar: context.calendar) {
        case .failure(.message(let message)):
            return .failed(message)
        case .success(let placed):
            return .commit(EditResult(baseRevision: context.revision, edits: TextEdit.between(context.text, placed.text), selection: [placed.start..<placed.start]))
        }
    }
}

extension DocumentSession {
    /// Shortcuts' "Capture to Orgstar": `text` as `%i` in the template keyed `key` (the first
    /// when nil or empty), its prompts taking their defaults, filed without the capture window.
    /// The template used.
    public func capture(
        _ text: String, templateKey key: String?, templates: [CaptureTemplate], workspace: WorkspaceModel, clock: ClockModel,
        clipboard: String, userName: String
    ) -> Result<CaptureTemplate, CaptureError> {
        let key = key.flatMap { $0.isEmpty ? nil : $0 }
        guard let chosen = key.map({ key in templates.first { $0.key == key } }) ?? templates.first else {
            return .failure(CaptureError(message: "No capture template \"\(key ?? "")\""))
        }
        let context = CaptureContext(initial: text, clipboard: clipboard, userName: userName, allTags: (try? workspace.index.tags()) ?? [])
        let answers = Capture.questions(chosen.template, context: context).map { _ in "" }
        guard case .success(let filled) = Capture.fill(chosen.template, context: context, answers: answers) else {
            return .failure(CaptureError(message: "Can't fill template \"\(chosen.key)\""))
        }
        return chosen.resolved(workspace: workspace, session: self, clock: clock).flatMap { resolved in
            capture(filled.text, template: resolved.template, root: workspace.rootPaths.first, file: resolved.file)
        }.map { _ in chosen }
    }
}

extension CaptureTemplate {
    /// `id` and `clock` targets as a file and a heading.
    @MainActor
    public func resolved(
        workspace: WorkspaceModel, session: DocumentSession, clock: ClockModel
    ) -> Result<(template: CaptureTemplate, file: String?), CaptureError> {
        switch target {
        case .id(let id):
            guard let location = try? workspace.index.headings(withID: id).first else {
                return .failure(CaptureError(message: "Cannot find target ID \"\(id)\""))
            }
            return .success((self, location.path))
        case .clock:
            guard let entry = clock.entry(session) else { return .failure(CaptureError(message: "No running clock")) }
            return .success((retargeted(.heading(file: entry.path, offset: entry.offset)), entry.path))
        default:
            return .success((self, nil))
        }
    }
}
