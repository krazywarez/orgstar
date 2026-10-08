import Foundation
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

    @Test func shadedBlocks() {
        let text = "* a\n#+begin_src sh\nls\n#+end_src\n\n- item\n  #+begin_quote\n  q\n  #+end_quote\n: fixed\n"
        let ns = text as NSString
        let ranges = Presentation.shadedBlocks(OrgParser.parse(text))
        #expect(ranges.map { ns.substring(with: NSRange($0)) } == [
            "#+begin_src sh\nls\n#+end_src", "  #+begin_quote\n  q\n  #+end_quote", ": fixed",
        ])
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

struct CyclingTests {
    let text = "* a\nbody\n** b\nmore\n*** c\ndeep\n* d\n"
    var tree: OrgTree { OrgParser.parse(text) }

    @Test func outline() {
        let entries = Presentation.outline(tree)
        #expect(entries.map(\.title) == ["a", "b", "c", "d"])
        #expect(entries.map(\.parent) == [nil, 0, 1, nil])
        #expect(entries.map(\.isTopLevel) == [true, false, false, true])
    }

    @Test func localCycle() {
        var state = FoldState()
        state = Presentation.cycle(0, in: tree, state)
        #expect(state == FoldState(folds: [0]))
        state = Presentation.cycle(0, in: tree, state)
        #expect(state == FoldState(folds: [9]))
        state = Presentation.cycle(0, in: tree, state)
        #expect(state == FoldState())
        #expect(Presentation.cycle(30, in: tree, FoldState(folds: [30])) == FoldState())
    }

    @Test func globalStates() {
        #expect(Presentation.foldState(for: .overview, in: tree) == FoldState(folds: [0, 30]))
        #expect(Presentation.foldState(for: .contents, in: tree) == FoldState(bodyFolds: [0, 9, 19, 30]))
        #expect(Presentation.cycleGlobal(from: nil, in: tree).0 == .overview)
        #expect(Presentation.cycleGlobal(from: .overview, in: tree).0 == .contents)
        #expect(Presentation.cycleGlobal(from: .contents, in: tree).0 == .showAll)
    }

    @Test func bodyFoldsKeepChildHeadings() {
        #expect(Presentation.hiddenRanges(tree, folds: [], bodyFolds: [0, 9, 19, 30]) == [4..<9, 14..<19, 25..<30])
    }

    @Test func startup() {
        #expect(Presentation.startupFoldState(OrgParser.parse("#+STARTUP: content\n" + text)) != nil)
        #expect(Presentation.startupFoldState(OrgParser.parse(text)) == nil)
        let levels = OrgParser.parse("#+startup: show2levels\n" + text)
        let state = Presentation.startupFoldState(levels)
        #expect(state?.folds.count == 1 && state?.bodyFolds.count == 2)
        #expect(Presentation.startupOptions(OrgParser.parse("#+begin_example\n#+STARTUP: overview\n#+end_example\n")).isEmpty)
        #expect(Presentation.startupOptions(OrgParser.parse("#+STARTUP: content\n* a\n:LOGBOOK:\n#+startup: hideblocks\n:END:\n")) == ["content", "hideblocks"])
    }
}

struct ThemeSpecTests {
    @Test func readsColorsOverTheDefault() throws {
        let tables = try TOML.parse("""
            [theme]
            font = "Menlo"
            link = "#112233"
            [theme.dark]
            link = "#445566cc"
            heading-1 = "blue"
            sparkle = "#000000"
            [theme.todo]
            WAIT = "#bf8700"
            """)
        let (spec, problems) = ThemeSpec.reading(tables)
        #expect(spec.light["link"] == RGBA(hex: "#112233"))
        #expect(spec.dark["link"]?.hex == "#445566cc")
        #expect(spec.dark["heading-1"] == ThemeSpec.default.dark["heading-1"])
        #expect(spec.todo["WAIT"]?.hex == "#bf8700")
        #expect(problems.count == 2)
    }

    @Test func defaultThemeFileReadsBackAsTheDefault() throws {
        let (spec, problems) = ThemeSpec.reading(try TOML.parse(ThemeSpec.defaultThemeFile()), over: ThemeSpec(light: [:], dark: [:]))
        #expect(problems.isEmpty)
        #expect(spec.light == ThemeSpec.default.light && spec.dark == ThemeSpec.default.dark)
        let defaulted = Set(ThemeSpec.slots.map(\.key)).subtracting(ThemeSpec.systemDefaults)
        #expect(Set(ThemeSpec.default.light.keys) == defaulted)
        #expect(Set(ThemeSpec.default.dark.keys) == defaulted)
    }
}
