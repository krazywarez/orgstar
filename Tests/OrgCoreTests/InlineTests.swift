import Testing
@testable import OrgCore

/// `kind:text` for each object directly inside the first paragraph.
func objects(_ text: String) -> [String] {
    let paragraph = OrgParser.parse(text).root.descendants().first { $0.kind == .paragraph }!
    return paragraph.children.map { "\($0.kind.rawValue):\($0.text)" }
}

struct InlineTests {
    @Test(arguments: [
        ("*b* /i/ _u_ +s+ =v= ~c~", ["bold:*b*", "italic:/i/", "underline:_u_", "strikeThrough:+s+", "verbatim:=v=", "code:~c~"]),
        ("a*b* (*c*) \"*d*\"", ["bold:*c*", "bold:*d*"]),
        ("x *y * z", []),
        ("*y*z", []),
        ("*a\nb*", ["bold:*a\nb*"]),
        ("*a\nb\nc*", []),
        ("=*not bold*=", ["verbatim:=*not bold*="]),
        ("[[https://a.b][the *site*]]", ["link:[[https://a.b][the *site*]]"]),
        ("[[file:x.org]]", ["link:[[file:x.org]]"]),
        ("<https://a.b/c>", ["link:<https://a.b/c>"]),
        ("see https://a.b/c.", ["link:https://a.b/c"]),
        ("<2026-10-04 Sun 10:00-11:30 +1w -2d>", ["timestamp:<2026-10-04 Sun 10:00-11:30 +1w -2d>"]),
        ("[2026-10-04 Sun]--[2026-10-06 Tue]", ["timestamp:[2026-10-04 Sun]--[2026-10-06 Tue]"]),
        ("a [fn:1] and [fn::inline [x] note]", ["footnoteReference:[fn:1]", "footnoteReference:[fn::inline [x] note]"]),
        ("a [1/3] [50%]", ["statisticsCookie:[1/3]", "statisticsCookie:[50%]"]),
        ("a <<target>> {{{m(x, y)}}}", ["target:<<target>>", "macro:{{{m(x, y)}}}"]),
        ("\\(x^2\\) and src_sh[:results raw]{echo {a}}", ["latexFragment:\\(x^2\\)", "inlineSourceBlock:src_sh[:results raw]{echo {a}}"]),
        ("N^2 and e^{i}", ["superscript:^2", "superscript:^{i}"]),
        ("end\\\\\nnext", ["lineBreak:\\\\"]),
    ])
    func recognizes(text: String, expected: [String]) {
        #expect(objects(text) == expected)
    }

    @Test func emphasisNests() {
        let bold = OrgParser.parse("*bold /italic/ x*\n").root.descendants().first { $0.kind == .bold }!
        #expect(bold.children.map(\.kind) == [.italic])
        #expect(bold.tokens.first?.kind == .marker)
    }

    @Test func linkParts() {
        let link = OrgParser.parse("[[id:abc][desc]]\n").root.descendants().first { $0.kind == .link }!
        #expect(link.tokens.map(\.kind) == [.marker, .linkPath, .marker, .marker])
        #expect(link.tokens.first { $0.kind == .linkPath }?.text == "id:abc")
        #expect(link.children.map(\.kind) == [.linkDescription])
    }

    @Test func noLinksInsideLinkDescriptions() {
        let link = OrgParser.parse("[[a][see https://b.c]]\n").root.descendants().first { $0.kind == .link }!
        #expect(link.descendants().filter { $0.kind == .link }.count == 1)
    }

    @Test func headingTitlesHoldObjects() {
        let title = OrgParser.parse("* TODO Read [[https://a.b][it]] [1/2]\n").root.descendants().first { $0.kind == .title }!
        #expect(title.children.map(\.kind) == [.link, .statisticsCookie])
    }

    @Test func planningHoldsTimestamps() {
        let planning = OrgParser.parse("* a\nDEADLINE: <2026-10-04 Sun -2d> SCHEDULED: <2026-10-01 Thu>\n").root
            .descendants().first { $0.kind == .planning }!
        #expect(planning.children.map(\.kind) == [.timestamp, .timestamp])
    }

    @Test func itemsSplitBulletAndCheckbox() {
        let item = OrgParser.parse("  - [X] done *now*\n    more\n").root.descendants().first { $0.kind == .item }!
        #expect(item.tokens.map(\.kind) == [.whitespace, .bullet, .whitespace, .checkbox, .whitespace])
        #expect(item.children.map(\.kind) == [.paragraph])
        #expect(item.children[0].text == "done *now*\n    more\n")
    }

    @Test func emptyItem() {
        let item = OrgParser.parse("-\n").root.descendants().first { $0.kind == .item }!
        #expect(item.tokens.map(\.kind) == [.bullet, .newline])
    }

    @Test func tableCells() {
        let rows = OrgParser.parse("| *a* || b\n|---+---|\n").root.descendants().filter { $0.kind == .tableRow }
        #expect(rows[0].children.map(\.text) == [" *a* ", "", " b"])
        #expect(rows[0].children[0].children.map(\.kind) == [.bold])
        #expect(rows[1].children.isEmpty)
    }

    @Test func footnoteDefinitionLabelIsNotAReference() {
        let definition = OrgParser.parse("[fn:1] see [fn:2]\n").root.descendants().first { $0.kind == .footnoteDefinition }!
        #expect(definition.tokens.first?.text == "[fn:1]")
        #expect(definition.children.map(\.kind) == [.footnoteReference])
    }
}
