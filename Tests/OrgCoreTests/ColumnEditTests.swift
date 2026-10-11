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

/// The `columnview` block's `:id` sources and `:match`, against Emacs visiting the files.
struct ColumnViewSourceTests {
    static let a = """
    #+COLUMNS: %25ITEM %TODO %Effort{:}
    #+BEGIN: columnview
    #+END:
    * Local :work:
    :PROPERTIES:
    :ID:       local-one
    :END:
    ** TODO Child :home:
    :PROPERTIES:
    :Effort:   0:20
    :END:
    ** Other child :work:
    :PROPERTIES:
    :Effort:   0:40
    :END:

    """
    static let b = """
    #+COLUMNS: %ITEM %Owner %Effort{:}
    * Bee project
    :PROPERTIES:
    :ID:       bee-id
    :END:
    ** Task :work:
    :PROPERTIES:
    :Owner:    Ada
    :Effort:   1:00
    :END:
    * Elsewhere
    :PROPERTIES:
    :Owner:    Bob
    :END:

    """

    static let params = [
        ":id \"file:b.org\"", ":id bee-id", ":id local-one", ":id global :match \"work\"", ":id global :match \"-home\" :maxlevel 2",
        ":id \"file:b.org\" :match \"Owner=\\\"Ada\\\"\"", ":id local-one :match \"TODO=\\\"TODO\\\"\"",
    ]

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func sourcesLikeOrg() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-colview-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let aPath = folder.appendingPathComponent("a.org").path
        let bPath = folder.appendingPathComponent("b.org").path
        for param in Self.params {
            let text = Self.a.replacingOccurrences(of: "#+BEGIN: columnview\n", with: "#+BEGIN: columnview \(param)\n")
            try text.write(toFile: aPath, atomically: true, encoding: .utf8)
            try Self.b.write(toFile: bPath, atomically: true, encoding: .utf8)
            let form = """
            (progn
              (require 'org) (require 'org-colview) (require 'org-id)
              (setq org-agenda-files (list "\(aPath)" "\(bPath)") org-id-locations-file "\(folder.path)/ids")
              (find-file "\(aPath)")
              (goto-char (point-min))
              (re-search-forward "^#\\\\+BEGIN:")
              (beginning-of-line)
              (org-update-dblock)
              (princ (buffer-string)))
            """
            let emacs = try EmacsOracle.run(["-Q", "--batch", "--eval", form], environment: ["TZ": "UTC"])
            var options = EditingOptions.org
            options.filePath = aPath
            options.agendaFiles = [aPath, bPath]
            let caret = (text as NSString).range(of: "#+BEGIN").location
            let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], options: options)
            var ours = text
            switch UpdateDynamicBlock().run(in: context) {
            case .commit(let result):
                for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { ours = edit.apply(to: ours) }
            case .failed(let message): ours = "failed: \(message)"
            default: ours = "other"
            }
            #expect(emacs.hasSuffix(ours), "\(param)\nours:\n\(ours)\nemacs:\n\(emacs)")
        }
    }
}
