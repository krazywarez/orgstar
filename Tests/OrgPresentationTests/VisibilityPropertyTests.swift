import Foundation
import Testing
import OrgCore
@testable import OrgPresentation

struct VisibilityPropertyTests {
    static let text = "#+STARTUP: overview\n* A\n:PROPERTIES:\n:VISIBILITY: children\n:END:\nbody a\n** A1\na1 body\n*** A11\n** A2\n* B\n:PROPERTIES:\n:VISIBILITY: content\n:END:\nbody b\n** B1\nb1 body\n*** B11\nb11\n* C\n:PROPERTIES:\n:VISIBILITY: all\n:END:\nbody c\n** C1\nc1\n* D :ARCHIVE:\n** D1\n* E\n:PROPERTIES:\n:VISIBILITY: folded\n:END:\n** E1\n"

    /// Line visibility after opening the file, as Emacs 31.1 / Org 9.8.7 shows it, except that
    /// Emacs leaves B's `:PROPERTIES:` line (line 12) showing under `content`.
    static let emacs = "111001100110000101011001111010000"

    @Test func foldsByVisibilityProperties() {
        let tree = OrgParser.parse(Self.text)
        var state = Presentation.applyVisibilityProperties(Presentation.startupFoldState(tree)!, in: tree)
        let wrappers = Presentation.startupWrappers(tree)
        state.wrapperFolds = Set(wrappers.map(\.start))
        let hidden = Presentation.hiddenRanges(tree, folds: state.folds, bodyFolds: state.bodyFolds, wrapperRanges: wrappers.map(\.hidden))
        let ns = Self.text as NSString
        var visibility = ""
        var offset = 0
        while offset < ns.length {
            visibility += hidden.contains { $0.contains(offset) } ? "0" : "1"
            offset = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
        }
        var expected = Array(Self.emacs)
        expected[11] = "0"
        #expect(visibility == String(expected))
    }
}
