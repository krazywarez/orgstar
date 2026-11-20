import Foundation
import OrgCore
import OrgDocument
import Testing
@testable import OrgApp

/// Answers every block with a fixed output and every table with fixed text.
private struct StubPrograms: ProgramRunning {
    func runBabel(_ job: BabelJob, fileDirectory: URL) async throws -> BabelOutput {
        BabelOutput(stdout: "stub")
    }

    func recalculateTable(text: String, directory: URL, table: Range<Int>, point: Int, form: String) async throws -> String {
        "| 1 |\n"
    }
}

/// The app creates its session before it sets `DocumentSession.programs`, so the runner is
/// read when a block or table runs, not when the session is made.
@MainActor
struct ProgramRunningTests {
    @Test func aRunnerSetAfterTheSessionOpensIsUsed() async throws {
        #expect(DocumentSession.runner == nil)
        let notes = try Folder()
        let file = try notes.write("b.org", "#+begin_src sh\necho hi\n#+end_src\n\n| 2 |\n")
        let session = DocumentSession(recovery: FileRecoveryStore(directory: notes.url.appendingPathComponent(".r")))
        session.open(file.path)
        guard case .external(.babel(let job)) = session.perform(ExecuteSrcBlock(), path: file.path, at: 3, expect: nil) else {
            Issue.record("not planned")
            return
        }
        let table = ("#+begin_src sh\necho hi\n#+end_src\n\n" as NSString).length
        await DocumentSession.$scopedPrograms.withValue(StubPrograms()) {
            #expect(await session.recalculateInEmacs(table: table..<(table + 6), point: table, form: "") == "Recalculated in Emacs")
            #expect(await session.runBabel(job) == "Code block evaluation complete.")
        }
        #expect(session.document?.text == "#+begin_src sh\necho hi\n#+end_src\n\n#+RESULTS:\n: stub\n\n| 1 |\n")
    }
}
