import Foundation
import Testing
import OrgPresentation
@testable import OrgEditorAppKit

struct LineIndexTests {
    func naive(_ text: String) -> [Int] {
        var starts = [0]
        for (i, u) in text.utf16.enumerated() where u == 10 { starts.append(i + 1) }
        return starts
    }

    @Test func followsRandomEdits() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "bc\n", "\n", "\n\n", "xyz", "é\n", "😀", ""]
        var text = "first\nsecond\n\nthird"
        let index = LineIndex(text as NSString)
        for _ in 0..<2000 {
            let ns = text as NSString
            let start = Int.random(in: 0...ns.length, using: &generator)
            let end = min(ns.length, start + Int.random(in: 0...6, using: &generator))
            let replacement = pieces.randomElement(using: &generator)!
            text = ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: replacement)
            index.replace(start..<end, newLength: (replacement as NSString).length, in: text as NSString)
            #expect(index.starts == naive(text))
            if index.starts != naive(text) { return }
        }
        #expect(index.line(of: 0) == 1)
        #expect(index.line(of: (text as NSString).length) == naive(text).count)
    }
}

@MainActor
struct ShadedBlockTests {
    /// Bands after edits match a full search once typing settles.
    @Test func incrementalMatchesFull() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["x", "word ", "\n", "#+begin_src sh\n", "#+end_src\n", ": fixed\n", "* H\n", "#+begin_quote\n", "#+end_quote\n", ""]
        let h = Harness("* A\n#+begin_src sh\nls\n#+end_src\ntext\n: one\n* B\nbody\n")
        for _ in 0..<400 {
            let length = h.editor.document.text.utf16.count
            let start = Int.random(in: 0...length, using: &generator)
            let end = min(length, start + Int.random(in: 0...5, using: &generator))
            let piece = pieces.randomElement(using: &generator)!
            h.textView.insertText(piece, replacementRange: NSRange(location: start, length: end - start))
            h.editor.settleBlocks()
            let full = Presentation.shadedBlocks(h.editor.document.tree)
            #expect(h.editor.shaded.all == full, "\(h.editor.document.text)")
            if h.editor.shaded.all != full { return }
        }
    }
}
