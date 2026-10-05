import Foundation
import Observation
import OrgCore
import OrgIndex

/// The day/week agenda over the workspace's agenda files. Sources are read from disk and
/// cached by modification date and size; the open file's come from its buffer, so the agenda
/// shows unsaved edits.
@MainActor
@Observable
public final class AgendaModel {
    public private(set) var days: [AgendaDay] = []
    /// The entries of a TODO list or match view.
    public private(set) var list: [AgendaItem] = []
    public var mode: AgendaMode = .agenda(span: nil, startOffset: nil)
    /// The first day shown, as `Days` numbers it; nil follows today.
    public var start: Int?
    public var span = 10
    /// Where the view starts relative to today, as Doom's `org-agenda-start-day "-3d"`.
    public var startOffset = -3
    /// Files below the top level of each folder are agenda files too.
    public var includeSubfolders = false
    public var options = AgendaOptions()
    public private(set) var isComputing = false

    private let workspace: WorkspaceModel
    @ObservationIgnored private var cache: [String: (mtime: Date, size: Int, source: AgendaSource)] = [:]
    @ObservationIgnored private var generation = 0

    public init(workspace: WorkspaceModel) {
        self.workspace = workspace
    }

    /// Org files directly in each folder (or below it, with `includeSubfolders`), by path, as
    /// Emacs lists a directory in `org-agenda-files`.
    public var files: [String] {
        workspace.files
            .filter { $0.kind == .org && (includeSubfolders || !$0.relativePath.contains("/")) }
            .map(\.path)
            .sorted()
    }

    /// Recomputes the days. `open` is the open file's path and text.
    public func refresh(open: (path: String, text: String)?, now: Date = Date(), calendar: Calendar = .current) async {
        generation += 1
        let id = generation
        isComputing = true
        let today = Days.absolute(now, calendar: calendar)
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        var span = self.span
        var startOffset = self.startOffset
        if case .agenda(let viewSpan, let viewStart) = mode {
            span = viewSpan ?? span
            startOffset = viewStart ?? startOffset
        }
        let first = start ?? today + startOffset
        let defaults = workspace.settings.org
        var reads: [(path: String, cached: AgendaSource?, mtime: Date, size: Int, text: String?)] = []
        for path in files {
            if let open, open.path == path {
                reads.append((path, nil, .distantPast, -1, open.text))
                continue
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = attributes?[.modificationDate] as? Date ?? .distantPast
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            let cached = cache[path].flatMap { $0.mtime == mtime && $0.size == size ? $0.source : nil }
            reads.append((path, cached, mtime, size, nil))
        }
        let options = self.options
        let mode = self.mode
        let result = await Task.detached {
            var sources: [(path: String, mtime: Date, size: Int, source: AgendaSource, fromDisk: Bool)] = []
            for read in reads {
                if let cached = read.cached {
                    sources.append((read.path, read.mtime, read.size, cached, true))
                } else if let text = read.text {
                    sources.append((read.path, read.mtime, read.size, AgendaSource(path: read.path, text: text, defaults: defaults), false))
                } else if let data = FileManager.default.contents(atPath: read.path) {
                    let text = SourceText(bytes: [UInt8](data)).text
                    sources.append((read.path, read.mtime, read.size, AgendaSource(path: read.path, text: text, defaults: defaults), true))
                }
            }
            let all = sources.map(\.source)
            var days: [AgendaDay] = []
            var list: [AgendaItem] = []
            switch mode {
            case .agenda:
                days = Agenda.list(all, start: first, days: span, today: today, now: (clock.hour ?? 0, clock.minute ?? 0), options: options)
            case .todo(let keywords):
                list = Agenda.todoList(all, keywords: keywords)
            case .match(let match, let todoOnly):
                list = Agenda.tagsMatch(all, match: match, todoOnly: todoOnly, now: now, calendar: calendar)
            }
            return (sources, days, list)
        }.value
        guard id == generation else { return }
        for source in result.0 where source.fromDisk {
            cache[source.path] = (source.mtime, source.size, source.source)
        }
        days = result.1
        list = result.2
        isComputing = false
    }

    public func showToday() { start = nil }

    /// Moves the view by a whole span, forward or back.
    public func shift(forward: Bool, now: Date = Date(), calendar: Calendar = .current) {
        var span = self.span
        var startOffset = self.startOffset
        if case .agenda(let viewSpan, let viewStart) = mode {
            span = viewSpan ?? span
            startOffset = viewStart ?? startOffset
        }
        let current = start ?? Days.absolute(now, calendar: calendar) + startOffset
        start = current + (forward ? span : -span)
    }
}
