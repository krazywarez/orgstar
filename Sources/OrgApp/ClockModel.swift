import Foundation
import Observation
import OrgCore

/// The running clock, kept across launches as Emacs keeps `org-clock-marker` for the session,
/// and the commands that start and stop it.
@MainActor
@Observable
public final class ClockModel {
    public struct Running: Codable, Equatable, Sendable {
        public let path: String
        /// The stamp in `CLOCK: [start]`.
        public let start: String
        public let heading: String
        public let startedAt: Date
    }

    public private(set) var running: Running?
    private let file: URL

    public init(file: URL = WorkspaceModel.defaultDirectory.appendingPathComponent("clock.json")) {
        self.file = file
        running = (try? JSONDecoder().decode(Running.self, from: Data(contentsOf: file)))
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let running, let data = try? JSONEncoder().encode(running) {
            try? data.write(to: file, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// `org-clock-in` at the heading under the caret, clocking out a running clock first.
    public func clockIn(_ session: DocumentSession, now: Date = Date()) -> String {
        guard let path = session.path, session.document != nil else { return "No file is open." }
        return clockIn(session, path: path, at: session.caret, now: now)
    }

    /// `org-clock-in` at the heading containing `offset` in `path`.
    public func clockIn(_ session: DocumentSession, path: String, at offset: Int, now: Date = Date()) -> String {
        guard let text = Self.text(path, session) else { return "Can't read \(path)" }
        let tree = OrgParser.parse(text)
        guard let entry = DocumentModel(tree: tree).headings.last(where: { $0.headingRange.lowerBound <= offset }) else { return "Before first headline" }
        if running != nil {
            let message = clockOut(session, now: now)
            if running != nil { return message }
        }
        switch session.perform(ClockIn(), path: path, at: offset, expect: nil, now: now) {
        case .commit:
            guard let updated = Self.text(path, session), let start = ClockIn.runningStart(in: updated, near: entry.headingRange.lowerBound) else {
                return "The clock line wasn't found after clocking in."
            }
            running = Running(path: path, start: start, heading: entry.title, startedAt: now)
            save()
            return "Clock starts at [\(start)]"
        case .failed(let message):
            return message
        default:
            return "Can't clock in here."
        }
    }

    /// `org-clock-out`, or `org-clock-cancel` with `cancel`.
    public func clockOut(_ session: DocumentSession, cancel: Bool = false, now: Date = Date()) -> String {
        guard let clock = running else { return "No active clock" }
        switch session.perform(ClockOut(start: clock.start, cancel: cancel), path: clock.path, at: 0, expect: nil, now: now) {
        case .commit:
            running = nil
            save()
            if cancel { return "Clock canceled" }
            let minutes = Int(now.timeIntervalSince(clock.startedAt) / 60)
            return String(format: "Clock stopped after %d:%02d", minutes / 60, minutes % 60)
        case .failed(let message):
            if message == "Clock start time is gone" || message == "No active clock" {
                running = nil
                save()
            }
            return message
        default:
            return "Can't clock out."
        }
    }

    /// A template's `clock-in` once its entry is filed: clocked from when capture began and,
    /// without `clock-keep`, clocked out now, the clock it interrupted resuming with
    /// `clock-resume`. The messages, in order.
    public func captured(
        _ entry: (path: String, offset: Int), options: CaptureTemplate.Options, session: DocumentSession, opened: Date, now: Date = Date()
    ) -> [String] {
        guard options.clockIn else { return [] }
        let previous = self.entry(session)
        var messages = [clockIn(session, path: entry.path, at: entry.offset, now: opened)]
        if !options.clockKeep {
            messages.append(clockOut(session, now: now))
            if options.clockResume, let previous {
                messages.append(clockIn(session, path: previous.path, at: previous.offset, now: now))
            }
        }
        return messages
    }

    static func text(_ path: String, _ session: DocumentSession) -> String? {
        session.openDocuments.first { $0.path == path }?.document.text ?? (try? String(contentsOfFile: path, encoding: .utf8))
    }

    /// The clocked entry's heading, for the `clock` capture target.
    public func entry(_ session: DocumentSession) -> (path: String, offset: Int)? {
        guard let line = location(session), let text = Self.text(line.path, session) else { return nil }
        let heading = DocumentModel(tree: OrgParser.parse(text)).headings.last { $0.headingRange.lowerBound <= line.offset }
        return heading.map { (line.path, $0.headingRange.lowerBound) }
    }

    /// Where the running clock's line is, for `org-clock-goto`.
    public func location(_ session: DocumentSession) -> (path: String, offset: Int)? {
        guard let clock = running else { return nil }
        let open = session.openDocuments.first { $0.path == clock.path }?.document.text
        guard let text = open ?? (try? String(contentsOfFile: clock.path, encoding: .utf8)) else { return nil }
        let buffer = text as NSString
        let range = buffer.range(of: "CLOCK: [\(clock.start)]")
        return range.location == NSNotFound ? (clock.path, 0) : (clock.path, range.location)
    }
}
