import Foundation
import Testing
@testable import OrgCore

/// `org-agenda-list-stuck-projects` against Emacs.
struct StuckProjectsTests {
    static let file = """
    * Projects
    ** Website
    *** TODO Draft the copy
    ** Garden :outdoor:
    *** WAIT Seeds
    *** Notes
    ** TODO Taxes
    ** Kitchen
    *** Buy tiles :errand:
    ** DONE Old project
    ** Reading
    Waiting for the library. NEXT week.
    ** IDEA Novel
    *** HOLD Outline :@home:
    * Areas
    ** Health
    *** STRT Running

    """

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func listsLikeOrg() throws {
        let today = Days.absolute(year: 2026, month: 10, day: 5)
        let cases: [(String, StuckProjects)] = [
            ("'(\"+LEVEL=2/-DONE\" (\"TODO\" \"NEXT\" \"NEXTACTION\") nil \"\")", StuckProjects()),
            ("'(\"+LEVEL=2/-DONE\" (\"*\") nil \"\")", StuckProjects(todo: ["*"])),
            ("'(\"+LEVEL=2/-DONE\" nil (\"errand\" \"@home\") \"\")", StuckProjects(todo: [], tags: ["errand", "@home"])),
            ("'(\"+LEVEL=2/-DONE\" nil (\"*\") \"\")", StuckProjects(todo: [], tags: ["*"])),
            ("'(\"+LEVEL=2/-DONE\" (\"WAIT\") nil \"\\\\<NEXT\\\\>\")", StuckProjects(todo: ["WAIT"], regexp: "\\<NEXT\\>")),
            ("'(\"LEVEL=2-outdoor\" (\"TODO\" \"STRT\") nil \"library\")", StuckProjects(match: "LEVEL=2-outdoor", todo: ["TODO", "STRT"], regexp: "library")),
        ]
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: Double((today - 719163) * 86400 + 9 * 3600 + 30 * 60))
        for (lisp, definition) in cases {
            try AgendaOracle.compareList(files: [("p.org", Self.file)], form: "(let ((org-stuck-projects \(lisp))) (org-agenda-list-stuck-projects))", today: today) {
                Agenda.stuckProjects($0, definition, now: now, calendar: utc)
            }
        }
    }
}
