import Foundation
import Testing
import OrgCore
@testable import OrgPresentation

struct ReadingTextTests {
    @Test func hidesLinkMarkupAndFoldedDrawers() {
        let text = "* TODO H :t:\n:PROPERTIES:\n:ID: x\n:END:\nSee [[https://a.org][the site]] and *b* [[c.org]].\n"
        let tree = OrgParser.parse(text)
        let folded = Presentation.startupWrappers(tree).map(\.hidden)
        let segments = ReadingText.segments(tree, in: 0..<(text as NSString).length, folded: folded)
        #expect(segments.map(\.text).joined() == "* TODO H :t:\n:PROPERTIES:…\nSee the site and *b* c.org.\n")
        // The drawer's first line and its `…` name the hidden range they open.
        #expect(segments.filter { $0.unfolds != nil }.map(\.text).joined() == ":PROPERTIES:…")
        #expect(segments.first { $0.text == "…" }?.unfolds == folded.first?.lowerBound)
        let site = segments.first { $0.text == "the site" }
        #expect(site?.link?.raw == "https://a.org" && site?.roles.contains(.link) == true)
        #expect(segments.first { $0.text == "TODO" }?.roles.contains(.todo) == true)
        #expect(segments.contains { $0.text == "b" && $0.roles.contains(.bold) })
        #expect(segments.first { $0.text.hasPrefix("c.org") }?.link?.path == "c.org")
        // Offsets point into the file.
        #expect(site.map { (text as NSString).substring(with: NSRange(location: $0.offset, length: 8)) } == "the site")
    }

    static func shown(_ text: String, _ display: ReadingText.Display) -> [ReadingText.Segment] {
        ReadingText.segments(OrgParser.parse(text), in: 0..<(text as NSString).length, display: display)
    }

    @Test func showMarkupShowsLinkBracketsAndEmphasisMarkers() {
        var options = EditingOptions.org
        options.hideEmphasisMarkers = true
        let text = "a *b* [[c.org][d]]\n"
        #expect(Self.shown(text, .init(options: options)).map(\.text).joined() == "a b d\n")
        #expect(Self.shown(text, .init(showMarkup: false)).map(\.text).joined() == "a *b* d\n")
        #expect(Self.shown(text, .init(showMarkup: true, options: options)).map(\.text).joined() == text)
    }

    @Test func prettyEntitiesShowTheirCharactersAndRaiseScripts() {
        var options = EditingOptions.org
        options.prettyEntities = true
        options.subSuperscriptsNeedBraces = true
        let text = "\\alpha and x^{2}\n#+begin_example\n\\beta\n#+end_example\n"
        let segments = Self.shown(text, .init(options: options))
        #expect(segments.map(\.text).joined() == "α and x2\n#+begin_example\n\\beta\n#+end_example\n")
        #expect(segments.first { $0.text == "2" }?.superscript == true)
        #expect(Self.shown(text, .init(showMarkup: true, options: options)).map(\.text).joined() == text)
    }

    struct Words: CodeHighlighter {
        func highlights(language: String, code: String) -> [(range: Range<Int>, category: SyntaxCategory)] {
            [(0..<4, .keyword)]
        }
    }

    @Test func highlightsSrcBlocks() {
        let text = "#+begin_src sh\necho hi\n#+end_src\n"
        let segments = Self.shown(text, .init(highlighter: Words()))
        #expect(segments.first { $0.text == "echo" }?.roles.contains(.syntax(.keyword)) == true)
    }
}
