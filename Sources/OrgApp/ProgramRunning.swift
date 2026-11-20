import Foundation
import OrgCore

/// Runs Babel jobs and Emacs as processes, for an app allowed to start them.
public protocol ProgramRunning: Sendable {
    /// Runs `job` in `fileDirectory`, or its `:dir`.
    func runBabel(_ job: BabelJob, fileDirectory: URL) async throws -> BabelOutput
    /// Runs `form` in Emacs on a copy of `text`; returns the table that starts at `table.lowerBound`.
    func recalculateTable(text: String, directory: URL, table: Range<Int>, point: Int, form: String) async throws -> String
}

extension DocumentSession {
    /// The runner for programs, set at launch by an app that may start them. Without one,
    /// only what runs natively runs.
    public static var programs: (any ProgramRunning)?

    /// Overrides `programs` for the current task and the tasks it starts.
    @TaskLocal public static var scopedPrograms: (any ProgramRunning)?

    static var runner: (any ProgramRunning)? { scopedPrograms ?? programs }
}
