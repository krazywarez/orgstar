#if os(macOS)
import Foundation
import OrgApp
import OrgCore

/// Babel and Emacs as processes, for `DocumentSession.programs`.
public struct Programs: ProgramRunning {
    public init() {}

    public func runBabel(_ job: BabelJob, fileDirectory: URL) async throws -> BabelOutput {
        // js in JavaScriptCore when node (or `:cmd`) isn't installed. A `:cmd` with arguments runs
        // as written, since JavaScriptCore can't take node's options.
        switch job.runner {
        case .process(let executable, _), .session(_, let executable, _):
            if !executable.contains(where: \.isWhitespace), !BabelRunner.installed(executable), let output = try await JavaScriptBlocks.run(job, directory: fileDirectory) { return output }
        case .emacs:
            break
        }
        return try await BabelRunner.run(job, fileDirectory: fileDirectory)
    }

    public func recalculateTable(text: String, directory: URL, table: Range<Int>, point: Int, form: String) async throws -> String {
        try await EmacsRunner.recalculateTable(text: text, directory: directory, table: table, point: point, form: form)
    }
}
#endif
