import Foundation
import Testing
@testable import OrgCore

/// `org-columns-next-allowed-value` and `org-columns-edit-value` against Emacs.
struct ColumnEditTests {
    static let text = """
    #+COLUMNS: %25ITEM %TODO %PRIORITY %Effort %Status %Done(Done){X} %SCHEDULED %DEADLINE
    #+PROPERTY: Effort_ALL 0:10 0:30 1:00
    * TODO [#B] Task one :work:
    SCHEDULED: <2026-10-05 Mon> DEADLINE: <2026-10-09 Fri>
    :PROPERTIES:
    :Effort:   0:30
    :Status_ALL: new open closed
    :Status:   open
    :END:
    * Task two
    Body.

    """

    /// Tags one space after the title: Emacs aligns them against column view's overlays.
    static func untagged(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \\t]+(:\\S+:)$", with: " $1", options: [.regularExpression])
            .components(separatedBy: "\n").map { $0.replacingOccurrences(of: "[ \\t]+(:[^ \\t]+:)$", with: " $1", options: .regularExpression) }
            .joined(separator: "\n")
    }

    static func run(_ command: any OrgCommand, at offset: Int) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [offset..<offset], calendar: utc)
        guard case .commit(let result) = command.run(in: context) else { return "failed" }
        var new = text
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
        return new
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func nextValuesLikeOrg() throws {
        let ns = Self.text as NSString
        let one = ns.range(of: "* TODO").location
        let two = ns.range(of: "* Task two").location
        let cases: [(Int, String, String?, Bool)] = [
            (one, "Effort", nil, false), (one, "Effort", nil, true), (one, "Status", nil, false), (one, "TODO", nil, false),
            (one, "PRIORITY", nil, false), (one, "PRIORITY", nil, true), (two, "Effort", nil, false), (two, "Done", "X", false),
            (two, "TODO", nil, true),
        ]
        var oracle: [EmacsOracle.Case] = []
        var ours: [String] = []
        for (offset, key, summary, previous) in cases {
            let form = """
            (progn (org-columns)
              (while (not (equal (get-char-property (point) 'org-columns-key) "\(key.uppercased())")) (forward-char 1))
              (org-columns-next-allowed-value \(previous ? "t" : "nil"))
              (org-columns-quit))
            """
            oracle.append(EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(offset, in: Self.text), form: form))
            ours.append(Self.run(NextColumnValue(property: key, summary: summary, previous: previous), at: offset + 2))
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(oracle)).enumerated() {
            #expect(Self.untagged(mine) == Self.untagged(theirs.text), "\(cases[i]) \(theirs.error)")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func editsLikeOrg() throws {
        let ns = Self.text as NSString
        let one = ns.range(of: "* TODO").location
        let two = ns.range(of: "* Task two").location
        let cases: [(Int, String, String)] = [
            (one, "ITEM", "Renamed task"), (two, "ITEM", "Second"), (one, "Status", "closed"), (one, "Effort", "2:00"), (two, "Effort", "0:10"),
            (two, "Status", "new"),
        ]
        var oracle: [EmacsOracle.Case] = []
        var ours: [String] = []
        for (offset, key, value) in cases {
            let form = """
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "\(value)"))
                      ((symbol-function 'completing-read) (lambda (&rest _) "\(value)")))
              (org-columns)
              (while (not (equal (get-char-property (point) 'org-columns-key) "\(key.uppercased())")) (forward-char 1))
              (org-columns-edit-value)
              (org-columns-quit))
            """
            oracle.append(EmacsOracle.Case(text: Self.text, point: EmacsOracle.point(offset, in: Self.text), form: form))
            ours.append(Self.run(SetColumnValue(property: key, value: value), at: offset))
        }
        for (i, (mine, theirs)) in zip(ours, try EmacsOracle.run(oracle)).enumerated() {
            #expect(Self.untagged(mine) == Self.untagged(theirs.text), "\(cases[i]) \(theirs.error)")
        }
    }

    /// Org 9.8.7 signals "Properties values should be strings" here; orgstar moves the date.
    @Test func shiftsPlanningDates() {
        let at = (Self.text as NSString).range(of: "* TODO").location + 3
        #expect(Self.run(NextColumnValue(property: "SCHEDULED"), at: at).contains("SCHEDULED: <2026-10-06 Tue>"))
        #expect(Self.run(NextColumnValue(property: "DEADLINE", previous: true), at: at).contains("DEADLINE: <2026-10-08 Thu>"))
    }

    @Test func specialsAndUnknowns() {
        let at = (Self.text as NSString).range(of: "* TODO").location + 3
        #expect(Self.run(SetColumnValue(property: "CLOCKSUM", value: "1:00"), at: at) == "failed")
        #expect(Self.run(NextColumnValue(property: "ITEM"), at: at) == "failed")
        #expect(Self.run(SetColumnValue(property: "TODO", value: "DONE"), at: at).contains("* DONE [#B] Task one"))
        #expect(Self.run(SetColumnValue(property: "TAGS", value: ":home:work:"), at: at).contains(":home:work:"))
    }
}
