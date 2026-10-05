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
        guard let entry = session.outline.last(where: { $0.start <= session.caret }) else { return "Before first headline" }
        if running != nil {
            let message = clockOut(session, now: now)
            if running != nil { return message }
        }
        switch session.perform(ClockIn(), path: path, at: session.caret, expect: nil, now: now) {
        case .commit:
            guard let updated = session.document?.text, let start = ClockIn.runningStart(in: updated, near: entry.start) else {
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

    /// Where the running clock's line is, for `org-clock-goto`.
    public func location(_ session: DocumentSession) -> (path: String, offset: Int)? {
        guard let clock = running else { return nil }
        let open = session.path == clock.path ? session.document?.text : nil
        guard let text = open ?? (try? String(contentsOfFile: clock.path, encoding: .utf8)) else { return nil }
        let buffer = text as NSString
        let range = buffer.range(of: "CLOCK: [\(clock.start)]")
        return range.location == NSNotFound ? (clock.path, 0) : (clock.path, range.location)
    }
}
