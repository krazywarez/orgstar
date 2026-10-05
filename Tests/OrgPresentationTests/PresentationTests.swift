import OrgCore
import Testing
@testable import OrgPresentation

func roles(_ text: String) -> [String] {
    let tree = OrgParser.parse(text)
    let utf16 = Array(text.utf16)
    return Presentation.styles(tree, in: 0..<utf16.count).map { run in
        "\(run.role):\(String(decoding: utf16[run.range], as: UTF16.self))"
    }
}

struct StyleTests {
    @Test func headingParts() {
        #expect(roles("** DONE [#A] Ship *it* :work:\n") == [
            "heading(level: 2):** DONE [#A] Ship *it* :work:\n",
            "leadingStars:*", "done:DONE", "priority:[#A]", "tags::work:",
            "bold:*it*", "markup:*", "markup:*",
        ])
    }

    @Test func describedLinksDimTheirTarget() {
        #expect(roles("[[https://a.b][site]]\n") == [
            "link:[[https://a.b][site]]", "linkMarkup:[[", "linkMarkup:https://a.b", "linkMarkup:][", "linkMarkup:]]",
        ])
        #expect(roles("[[https://a.b]]\n") == ["link:[[https://a.b]]", "linkMarkup:[[", "linkMarkup:]]"])
    }

    @Test func blocksAndMetadata() {
        #expect(roles("#+begin_src sh\necho\n#+end_src\n") == [
            "block:#+begin_src sh\necho\n#+end_src\n", "blockDelimiter:#+begin_src sh", "blockDelimiter:#+end_src",
        ])
        #expect(roles("* a\nSCHEDULED: <2026-10-04 Sun>\n").contains("metadata:SCHEDULED: <2026-10-04 Sun>\n"))
    }

    @Test func onlyRunsOverlappingTheRange() {
        let text = "* a\nfirst *b*\n* c\nsecond *d*\n"
        let tree = OrgParser.parse(text)
        let runs = Presentation.styles(tree, in: 17..<28)
        #expect(!runs.contains { $0.range == 10..<13 })
        #expect(runs.contains { $0.range == 25..<28 && $0.role == .bold })
    }
}

struct IndentTests {
    @Test func bodiesIndentPastTheirStars() {
        let text = "pre\n* a\nbody\n** b\nmore\n"
        let runs = Presentation.indents(OrgParser.parse(text), in: 0..<text.utf16.count)
        #expect(runs == [
            IndentRun(range: 4..<8, firstLine: 0, wrapped: 2),
            IndentRun(range: 8..<13, firstLine: 2, wrapped: 2),
            IndentRun(range: 13..<18, firstLine: 0, wrapped: 3),
            IndentRun(range: 18..<23, firstLine: 3, wrapped: 3),
        ])
    }
}

struct FoldTests {
    let text = "* a\nbody\n** b\nmore\n* c\ntext\n"

    @Test func hiddenRanges() {
        let tree = OrgParser.parse(text)
        #expect(Presentation.hiddenRanges(tree, folds: [0]) == [4..<19])
        #expect(Presentation.hiddenRanges(tree, folds: [9]) == [14..<19])
        #expect(Presentation.hiddenRanges(tree, folds: [0, 9]) == [4..<19])
        #expect(Presentation.hiddenRanges(tree, folds: [19]) == [23..<28])
        #expect(Presentation.hiddenRanges(OrgParser.parse("* a"), folds: [0]).isEmpty)
    }

    @Test func headingContaining() {
        let tree = OrgParser.parse(text)
        #expect(Presentation.heading(containing: 2, in: tree) == 0)
        #expect(Presentation.heading(containing: 3, in: tree) == 0)
        #expect(Presentation.heading(containing: 5, in: tree) == nil)
        #expect(Presentation.heading(containing: 10, in: tree) == 9)
        #expect(Presentation.headings(tree) == [0, 9, 19])
    }
}
