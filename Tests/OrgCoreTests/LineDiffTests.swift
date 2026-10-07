import Foundation
import Testing
@testable import OrgCore

struct LineDiffTests {
    @Test func splitsAnEditSpanningSeveralLinesIntoTheLinesItChanges() {
        let text = "* Top\nText here.\n* Folded\n** Child\nbody\n* End\n"
        let new = "* Top\nText here.[fn:1]\n* Folded\n** Child\nbody\n* End\n\n* Footnotes\n\n[fn:1] \n"
        let one = TextEdit.between(text, new)
        #expect(one.count == 1)
        let split = splitByLines(one[0], in: text)
        #expect(split.count == 2)
        #expect(split.allSatisfy { !(text as NSString).substring(with: NSRange($0.range)).contains("* Folded") })
        var result = text
        for edit in split.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { result = edit.apply(to: result) }
        #expect(result == new)
    }

    @Test func leavesAnEditWithinALineAlone() {
        let text = "* a\nbc\n"
        let edit = TextEdit(range: 4..<5, replacement: "x")
        #expect(splitByLines(edit, in: text) == [edit])
    }
}
