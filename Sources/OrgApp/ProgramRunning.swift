import Foundation
import OrgCore

/// Runs Babel jobs and Emacs as processes, for an app allowed to start them.
public protocol ProgramRunning: Sendable {
    /// Runs `job` in `fileDirectory`, or its `:dir`.
    func runBabel(_ job: BabelJob, fileDirectory: URL) async throws -> BabelOutput
    /// Runs `form` in Emacs on a copy of `text`; returns the table that starts at `table.lowerBound`.
    func recalculateTable(text: String, directory: URL, table: Range<Int>, point: Int, form: String) async throws -> String
    /// Evaluates `form` in Emacs, in a copy of `text` with point at `point`, and returns its
    /// value as `%s` prints it; nil when there is no Emacs to run.
    func evaluateLisp(_ form: String, text: String, point: Int, directory: URL) async throws -> String?
}

extension ProgramRunning {
    public func evaluateLisp(_ form: String, text: String, point: Int, directory: URL) async throws -> String? { nil }
}

extension DocumentSession {
    /// The runner for programs, set at launch by an app that may start them. Without one,
    /// only what runs natively runs.
    public static var programs: (any ProgramRunning)?

    /// Overrides `programs` for the current task and the tasks it starts.
    @TaskLocal public static var scopedPrograms: (any ProgramRunning)?

    static var runner: (any ProgramRunning)? { scopedPrograms ?? programs }
}
