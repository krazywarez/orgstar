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
        let site = segments.first { $0.text == "the site" }
        #expect(site?.link?.raw == "https://a.org" && site?.roles.contains(.link) == true)
        #expect(segments.first { $0.text == "TODO" }?.roles.contains(.todo) == true)
        #expect(segments.contains { $0.text == "b" && $0.roles.contains(.bold) })
        #expect(segments.first { $0.text.hasPrefix("c.org") }?.link?.path == "c.org")
        // Offsets point into the file.
        #expect(site.map { (text as NSString).substring(with: NSRange(location: $0.offset, length: 8)) } == "the site")
    }
}
