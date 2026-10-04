import Testing
@testable import OrgCore

struct LinesTests {
    @Test func splitKeepsEveryEnding() {
        let lines = splitRawLines("a\r\nb\n\nc")
        #expect(lines.map { String($0.content) } == ["a", "b", "", "c"])
        #expect(lines.map { String($0.ending) } == ["\r\n", "\n", "\n", ""])
        #expect(splitRawLines("").isEmpty)
        #expect(splitRawLines("x\n").count == 1)
    }

    @Test func splitIsLossless() {
        let text = "\r\n\n a\r b\r\n😀\n"
        #expect(splitRawLines(text).map { String($0.content) + String($0.ending) }.joined() == text)
    }

    @Test(arguments: [
        ("", LineClass.blank),
        ("   \t", .blank),
        ("* a", .heading(level: 1)),
        ("*** ", .heading(level: 3)),
        ("*", .heading(level: 1)),
        ("*bold* text", .plain),
        (" * a", .listItem),
        ("#+BEGIN_SRC sh :results output", .blockBegin(name: "src")),
        ("#+end_src", .blockEnd(name: "src")),
        ("#+BEGIN: clocktable :scope file", .dynamicBegin),
        ("#+END:", .dynamicEnd),
        ("#+TITLE: x", .keyword(key: "TITLE")),
        ("#+tblfm: $2=$1", .keyword(key: "TBLFM")),
        ("# comment", .comment),
        ("#", .comment),
        ("#hashtag", .plain),
        (": fixed", .fixedWidth),
        (":", .fixedWidth),
        (":PROPERTIES:", .drawerBegin(name: "PROPERTIES")),
        ("  :LOGBOOK:", .drawerBegin(name: "LOGBOOK")),
        (":END:", .drawerEnd),
        ("| a | b |", .tableRow),
        ("-----", .horizontalRule),
        ("----", .plain),
        ("[fn:1] note", .footnoteDefinition),
        ("CLOCK: [2026-10-04 Sun 10:00]", .clock),
        ("SCHEDULED: <2026-10-04 Sun>", .planning),
        ("- item", .listItem),
        ("+ item", .listItem),
        ("1. item", .listItem),
        ("2) item", .listItem),
        ("-", .listItem),
        ("-x", .plain),
        ("1.5 apples", .plain),
        ("plain text", .plain),
    ])
    func classify(line: String, expected: LineClass) {
        #expect(classifyLine(line[...]).cls == expected)
    }

    @Test func indentCountsTabsToEight() {
        #expect(classifyLine("\t- a").indent == 8)
        #expect(classifyLine("  \t- a").indent == 8)
        #expect(classifyLine("   - a").indent == 3)
    }
}
