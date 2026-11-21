#if os(macOS)
import Foundation
import OrgApp
import OrgCore

/// Babel and Emacs as processes, for `DocumentSession.programs`.
public struct Programs: ProgramRunning {
    /// Where Emacs is, or nil when it isn't installed.
    let emacs: @Sendable () -> URL?

    public init(emacs: @escaping @Sendable () -> URL? = { EmacsRunner.executable() }) {
        self.emacs = emacs
    }

    public func runBabel(_ job: BabelJob, fileDirectory: URL) async throws -> BabelOutput {
        // js in JavaScriptCore when node (or `:cmd`) isn't installed. A `:cmd` with arguments runs
        // as written, since JavaScriptCore can't take node's options.
        switch job.runner {
        case .process(let executable, _), .session(_, let executable, _):
            if !executable.contains(where: \.isWhitespace), !BabelRunner.installed(executable), let output = try await JavaScriptBlocks.run(job, directory: fileDirectory) { return output }
        case .emacs:
            // Emacs Lisp in `Elisp` when Emacs isn't installed.
            if emacs() == nil {
                guard let output = try Babel.evaluateNatively(job) else {
                    throw BabelRunner.Failure(description: "This block uses Emacs Lisp that runs only in Emacs, and Emacs isn't installed.")
                }
                return output
            }
        }
        return try await BabelRunner.run(job, fileDirectory: fileDirectory)
    }

    public func recalculateTable(text: String, directory: URL, table: Range<Int>, point: Int, form: String) async throws -> String {
        try await EmacsRunner.recalculateTable(text: text, directory: directory, table: table, point: point, form: form)
    }

    /// `elisp:` links in Emacs; nil without it, so they run in `Elisp`.
    public func evaluateLisp(_ form: String, text: String, point: Int, directory: URL) async throws -> String? {
        guard emacs() != nil else { return nil }
        return try await EmacsRunner.evaluate(form, text: text, point: point, directory: directory)
    }
}
#endif
