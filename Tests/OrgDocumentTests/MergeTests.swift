import OrgCore
import Testing
@testable import OrgDocument

struct MergeTests {
    @Test func separateChangesMerge() {
        #expect(threeWayMerge(base: "a\nb\nc\n", ours: "A\nb\nc\n", theirs: "a\nb\nC\n") == .merged("A\nb\nC\n"))
    }

    @Test func sameChangeOnBothSidesMergesOnce() {
        #expect(threeWayMerge(base: "a\nb\n", ours: "a\nX\n", theirs: "a\nX\n") == .merged("a\nX\n"))
    }

    @Test func differentChangesConflict() {
        let result = threeWayMerge(base: "a\nb\nc\n", ours: "a\nX\nc\n", theirs: "a\nY\nc\n")
        #expect(result == .conflict([MergeConflict(base: "b\n", ours: "X\n", theirs: "Y\n")]))
    }

    @Test func insertionsAndDeletions() {
        #expect(threeWayMerge(base: "a\nb\n", ours: "a\nb\nc\n", theirs: "b\n") == .merged("b\nc\n"))
        #expect(threeWayMerge(base: "", ours: "x\n", theirs: "") == .merged("x\n"))
    }

    @Test func lineEndingsSurvive() {
        #expect(threeWayMerge(base: "a\r\nb\r\n", ours: "A\r\nb\r\n", theirs: "a\r\nb\r\nc") == .merged("A\r\nb\r\nc"))
    }

    @Test func lineEditsRebuildTheNewText() {
        let pairs = [("a\nb\nc\n", "a\nx\nc\nd\n"), ("", "x"), ("x", ""), ("a\r\nb", "b\r\na"), ("same\n", "same\n")]
        for (old, new) in pairs {
            var text = old
            for edit in lineEdits(from: old, to: new).reversed() { text = edit.apply(to: text) }
            #expect(text == new)
        }
    }

    @Test func largeFilesWithSmallChanges() {
        let base = (0..<20_000).map { "line \($0)\n" }.joined()
        let ours = base.replacingOccurrences(of: "line 100\n", with: "ours\n")
        let theirs = base.replacingOccurrences(of: "line 19000\n", with: "theirs\n")
        guard case .merged(let merged) = threeWayMerge(base: base, ours: ours, theirs: theirs) else {
            Issue.record("expected a clean merge")
            return
        }
        #expect(merged.contains("ours\n") && merged.contains("theirs\n"))
    }
}
