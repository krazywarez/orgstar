import Testing
@testable import OrgCore

struct SyntaxTreeTests {
    func sample() -> GreenNode {
        var b = GreenBuilder()
        b.start(.document)
        b.start(.paragraph)
        b.token(.text, "hé😀")
        b.token(.newline, "\n")
        b.finish()
        b.token(.newline, "\r\n")
        b.finish()
        return b.build()
    }

    @Test func lengthsAreUTF16() {
        let green = sample()
        #expect(green.length == 4 + 1 + 2)
        #expect(green.text == "hé😀\n\r\n")
    }

    @Test func redNodesCarryOffsets() {
        let root = SyntaxNode(green: sample(), offset: 0, parent: nil)
        let paragraph = root.children[0]
        #expect(paragraph.kind == .paragraph)
        #expect(paragraph.range == 0..<5)
        #expect(paragraph.parent === root)
        #expect(root.tokens.map(\.range) == [5..<7])
        #expect(paragraph.tokens.map(\.kind) == [.text, .newline])
    }

    @Test func builderSkipsEmptyTokens() {
        var b = GreenBuilder()
        b.start(.document)
        b.token(.whitespace, "")
        b.finish()
        #expect(b.build().children.isEmpty)
    }

    @Test func descendantsArePreorder() {
        let root = SyntaxNode(green: sample(), offset: 0, parent: nil)
        #expect(root.descendants().map(\.kind) == [.document, .paragraph])
    }
}
