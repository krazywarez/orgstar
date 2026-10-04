import Testing
@testable import OrgCore

func childKinds(_ text: String) -> [SyntaxKind] {
    let root = OrgParser.parse(text).root
    let container = root.children.first { $0.kind == .zerothSection || $0.kind == .section }!
    return container.children.map(\.kind)
}

struct ParserElementTests {
    @Test func planningAndPropertiesFollowHeading() {
        let text = "* a\nSCHEDULED: <2026-10-04 Sun>\n:PROPERTIES:\n:ID: x\n:END:\nbody\n"
        #expect(childKinds(text) == [.heading, .planning, .propertyDrawer, .paragraph])
    }

    @Test func planningElsewhereIsText() {
        #expect(childKinds("SCHEDULED: <2026-10-04 Sun>\n") == [.paragraph])
    }

    @Test func blocks() {
        #expect(childKinds("#+begin_src sh\n,* escaped\n:END:\n#+end_src\nafter\n") == [.block, .paragraph])
        #expect(childKinds("#+BEGIN: clocktable\n#+END:\n") == [.dynamicBlock])
    }

    @Test func headingsEndBlocks() {
        #expect(childKinds("#+begin_src sh\n* heading\n#+end_src\n") == [.paragraph])
    }

    @Test func unclosedBlockIsParagraph() {
        #expect(childKinds("#+begin_src sh\necho\n") == [.paragraph])
    }

    @Test func drawersHoldElements() {
        let root = OrgParser.parse(":LOGBOOK:\nCLOCK: [2026-10-04 Sun 10:00]\n:END:\n").root
        let drawer = root.children[0].children[0]
        #expect(drawer.kind == .drawer)
        #expect(drawer.children.map(\.kind) == [.clock])
    }

    @Test func keywords() {
        #expect(childKinds("#+TITLE: x\n#+NAME: t\n#+ATTR_HTML: :width 10\n") == [.keyword, .affiliatedKeyword, .affiliatedKeyword])
    }

    @Test func commentsAndFixedWidthGroup() {
        #expect(childKinds("# a\n# b\n: c\n: d\n-----\n") == [.comment, .fixedWidth, .horizontalRule])
    }

    @Test func tableWithFormulas() {
        let root = OrgParser.parse("| a |\n|---|\n| 1 |\n#+TBLFM: $1=2\n#+TBLFM: $1=3\n").root
        let table = root.children[0].children[0]
        #expect(table.kind == .table)
        #expect(table.children.map(\.kind) == [.tableRow, .tableRow, .tableRow, .tableFormula, .tableFormula])
    }

    @Test func footnoteDefinition() {
        #expect(childKinds("[fn:1] note\ncontinued\n\nafter\n") == [.footnoteDefinition, .paragraph])
    }

    @Test func listsNestByIndent() {
        let text = "- a\n  more\n  - b\n- c\n\nafter\n"
        let root = OrgParser.parse(text).root
        let list = root.children[0].children[0]
        #expect(list.kind == .plainList)
        #expect(list.children.map(\.kind) == [.item, .item])
        #expect(list.children[0].children.map(\.kind) == [.paragraph, .plainList])
        #expect(childKinds(text) == [.plainList, .paragraph])
    }

    @Test func twoBlankLinesEndAList() {
        #expect(childKinds("- a\n\n\n- b\n") == [.plainList, .plainList])
        #expect(childKinds("- a\n\n- b\n") == [.plainList])
    }

    @Test func paragraphStopsAtElementStart() {
        #expect(childKinds("text\n| a |\n") == [.paragraph, .table])
        #expect(childKinds("text\n#+begin_quote\nq\n#+end_quote\n") == [.paragraph, .block])
        #expect(childKinds("text\n#+begin_quote\nq\n") == [.paragraph])
    }
}
