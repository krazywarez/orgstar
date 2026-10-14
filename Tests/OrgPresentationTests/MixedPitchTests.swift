import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct MixedPitchTests {
    @Test func fixedPitchRoles() {
        for role: StyleRole in [.table, .rule, .block, .blockDelimiter, .verbatim, .code, .inlineSource, .metadata, .keyword, .tags, .timestamp, .syntax(.keyword)] {
            #expect(Presentation.isFixedPitch(role), "\(role)")
        }
        for role: StyleRole in [.heading(level: 1), .bold, .italic, .link, .comment, .todo, .markup, .footnote] {
            #expect(!Presentation.isFixedPitch(role), "\(role)")
        }
    }

    @Test func prefixesThatSetIndentation() {
        let text = "** Heading\nProse here.\n  indented prose\n- item\n  - [ ] box\n12. twelve\n\tTabbed\n*bold* not a heading\n" as NSString
        let prefixes = Presentation.fixedPitchPrefixes(text, in: 0..<text.length).map { text.substring(with: NSRange($0)) }
        #expect(prefixes == ["** ", "  ", "- ", "  - [ ] ", "12. ", "\t"])
    }

    @Test func prefixesOnlyInRange() {
        let text = "- a\n- b\n" as NSString
        #expect(Presentation.fixedPitchPrefixes(text, in: 4..<8) == [4..<6])
    }

    @Test func bodyFontInSpec() {
        var spec = ThemeSpec.default
        #expect(spec.bodyFont.isEmpty)
        spec.bodyFont = "system"
        #expect(spec != ThemeSpec.default)
    }
}
