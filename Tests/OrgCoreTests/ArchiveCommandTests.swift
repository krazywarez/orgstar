import Foundation
import Testing
@testable import OrgCore

struct ArchiveCommandTests {
    static let oracle = ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil

    @Test(.enabled(if: oracle))
    func archivesInPlaceLikeOrg() throws {
        let texts = [
            "* P [0/2]\n** TODO a :x:\nbody\n** TODO b\n* Q\n",
            "* P\n** a\n** Archive :ARCHIVE:\n*** old\n** b\n",
            "* top\n* other :ARCHIVE:\n",
            "* P\n** a\n\n** b\n",
        ]
        var cases: [EmacsOracle.Case] = []
        var ours: [(String, Int, String?)] = []
        for text in texts {
            let ns = text as NSString
            var starts: [Int] = []
            var offset = 0
            while offset < ns.length {
                if ns.character(at: offset) == 42 { starts.append(offset) }
                offset = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
            }
            for start in starts {
                for (command, form) in [(ToggleArchiveTag() as any OrgCommand, "(org-toggle-archive-tag)"), (ArchiveToSibling(), "(org-archive-to-archive-sibling)")] {
                    cases.append(EmacsOracle.Case(text: text, point: EmacsOracle.point(start + 1, in: text), form: frozenClock(1_789_000_000, form)))
                    var utc = Calendar(identifier: .gregorian)
                    utc.timeZone = TimeZone(identifier: "UTC")!
                    let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [(start + 1)..<(start + 1)],
                                              now: Date(timeIntervalSince1970: 1_789_000_000), calendar: utc)
                    switch command.run(in: context) {
                    case .commit(let result):
                        let new = result.edits.sorted { $0.range.lowerBound > $1.range.lowerBound }.reduce(text) { $1.apply(to: $0) }
                        ours.append((new, result.selection?.first?.lowerBound ?? start + 1, nil))
                    case .failed(let message): ours.append((text, start + 1, message))
                    default: ours.append((text, start + 1, "other"))
                    }
                }
            }
        }
        for (i, theirs) in try EmacsOracle.run(cases).enumerated() {
            let caret = EmacsOracle.offset(theirs.point, in: theirs.text)
            #expect(ours[i].0 == theirs.text && ours[i].1 == caret && (ours[i].2 != nil) == !theirs.error.isEmpty,
                    "\(cases[i].form) on \(cases[i].text.debugDescription) @\(cases[i].point)\nours:  \(ours[i].0.debugDescription) @\(ours[i].1) \(ours[i].2 ?? "")\nemacs: \(theirs.text.debugDescription) @\(caret) \(theirs.error)")
        }
    }
}
