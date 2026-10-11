import AppKit
import OrgCore
@testable import OrgEditorAppKit
import Testing

@MainActor
struct LatexPreviewEditorTests {
    static let text = "#+STARTUP: latexpreview\n* Math\nInline $x^2$ here.\n\\begin{equation}\na = b\n\\end{equation}\nEnd.\n"

    /// The layout fragment over `offset`.
    static func fragment(_ h: Harness, at offset: Int) -> NSTextLayoutFragment? {
        h.layout()
        let manager = h.editor.textLayoutManager
        let content = manager.textContentManager!
        guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        return manager.textLayoutFragment(for: location)
    }

    @Test func startupShowsPreviewsOffTheCaretLine() throws {
        let h = Harness(Self.text)
        #expect(h.editor.showsLatex)
        let ns = Self.text as NSString
        let dollar = ns.range(of: "$x^2$").location
        let storage = try #require(h.textView.textStorage)
        let box = try #require(storage.attribute(.orgLatex, at: dollar, effectiveRange: nil) as? LatexBox)
        #expect(box.rendering.size.width > 5 && !box.environment)
        let kern = storage.attribute(.kern, at: dollar + 4, effectiveRange: nil) as? CGFloat
        #expect((kern ?? 0) > 5)
        #expect(Self.fragment(h, at: dollar) is LatexFragment)
        let begin = ns.range(of: "\\begin").location
        #expect((storage.attribute(.orgLatex, at: begin, effectiveRange: nil) as? LatexBox)?.environment == true)

        // On the caret's line, the source.
        h.caret(at: dollar + 1)
        h.editor.revealCaretLine()
        #expect(storage.attribute(.orgLatex, at: dollar, effectiveRange: nil) == nil)

        h.editor.run("org.latex-preview")
        #expect(!h.editor.showsLatex)
        #expect(storage.attribute(.orgLatex, at: begin, effectiveRange: nil) == nil)
    }
}
