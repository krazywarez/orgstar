import AppKit
import OrgCore
@testable import OrgPresentation
import Testing

@MainActor
struct LatexPreviewTests {
    @Test func findsFragmentsAndEnvironments() {
        let text = """
            #+STARTUP: latexpreview
            * Math
            Inline $x^2$ and \\(a+b\\), display $$\\sum_i i$$ and \\[e^{i\\pi}\\], a \\frac{1}{2} and a price of $3.
            \\begin{align}
            a &= b \\\\
            c &= d
            \\end{align}
            #+begin_src latex
            $not$
            #+end_src
            """
        let tree = OrgParser.parse(text)
        let found = LatexPreview.fragments(tree, in: 0..<(text as NSString).length)
        #expect(found.map(\.latex) == ["x^2", "a+b", "\\sum_i i", "e^{i\\pi}", "\\frac{1}{2}", "\\begin{aligned}a &= b \\\\\nc &= d\\end{aligned}"])
        #expect(found.map(\.display) == [false, false, true, true, false, true])
        #expect(found.last?.environment == true)
        #expect((text as NSString).substring(with: NSRange(found[0].range)) == "$x^2$")
        #expect(Presentation.startupLatexPreview(tree) == true)
    }

    @Test func rendersMath() throws {
        let inline = try #require(LatexPreview.render("x^2 + \\frac{a}{b}", display: false, fontSize: 13, color: .black, scale: 2))
        #expect(inline.size.width > 20 && inline.ascent > 0 && inline.image.width == Int((inline.size.width * 2).rounded(.up)))
        let aligned = try #require(LatexPreview.render("\\begin{aligned}a &= b \\\\ c &= d\\end{aligned}", display: true, fontSize: 13, color: .black, scale: 2))
        #expect(aligned.size.height > inline.size.height)
        #expect(LatexPreview.render("\\frac{a}{", display: false, fontSize: 13, color: .black, scale: 2) == nil)
    }
}
