import Testing
@testable import OrgCore

func nodeKinds(_ text: String) -> [SyntaxKind] {
    OrgParser.parse(text).root.descendants().map(\.kind)
}

func tokens(of kind: SyntaxKind, in text: String) -> [SyntaxToken] {
    OrgParser.parse(text).root.descendants().filter { $0.kind == kind }.flatMap(\.tokens)
}

struct ParserSectionTests {
    @Test func emptyDocument() {
        let tree = OrgParser.parse("")
        #expect(tree.text == "")
        #expect(nodeKinds("") == [.document])
    }

    @Test func zerothSectionHoldsPreamble() {
        #expect(nodeKinds("text\n* a\n") == [.document, .zerothSection, .paragraph, .section, .heading])
    }

    @Test func sectionsNestByLevel() {
        let text = "* a\n** b\n*** c\n** d\n* e\n"
        let root = OrgParser.parse(text).root
        let top = root.children
        #expect(top.map(\.kind) == [.section, .section])
        #expect(top[0].children.map(\.kind) == [.heading, .section, .section])
        #expect(top[0].children[1].children.map(\.kind) == [.heading, .section])
    }

    @Test func headingTokens() {
        let parts = tokens(of: .heading, in: "** TODO [#A] Write the plan  :work:urgent:  \n")
        #expect(parts.map(\.kind) == [.stars, .whitespace, .todoKeyword, .whitespace, .priority, .whitespace, .title, .whitespace, .tags, .whitespace, .newline])
        #expect(parts.first { $0.kind == .tags }?.text == ":work:urgent:")
        #expect(parts.first { $0.kind == .title }?.text == "Write the plan")
    }

    @Test func todoKeywordsComeFromSettings() {
        let text = "#+TODO: NEXT | DONE\n* NEXT a\n* TODO b\n"
        let todo = tokens(of: .heading, in: text).filter { $0.kind == .todoKeyword }.map(\.text)
        #expect(todo == ["NEXT"])
    }

    @Test func priorityNeedsValidValueAndSpace() {
        #expect(tokens(of: .heading, in: "* [#B] x\n").contains { $0.kind == .priority })
        #expect(tokens(of: .heading, in: "* [#10] x\n").contains { $0.kind == .priority })
        #expect(!tokens(of: .heading, in: "* [#AB] x\n").contains { $0.kind == .priority })
        #expect(!tokens(of: .heading, in: "* [#A]x\n").contains { $0.kind == .priority })
    }

    @Test func tagsNeedValidCharacters() {
        #expect(tokens(of: .heading, in: "* a :b@c_1:\n").contains { $0.kind == .tags })
        #expect(!tokens(of: .heading, in: "* a :b c:\n").contains { $0.kind == .tags })
        #expect(!tokens(of: .heading, in: "* a :b:c\n").contains { $0.kind == .tags })
    }

    @Test func headingWithoutNewlineAtEnd() {
        #expect(OrgParser.parse("* a").text == "* a")
    }

    @Test(arguments: ["* a\n", "*\n", "* TODO\n", "text\r\n* a\r\n** b\r\n", "\n\n* a\n\n"])
    func roundTrip(text: String) {
        #expect(OrgParser.parse(text).text == text)
    }
}
