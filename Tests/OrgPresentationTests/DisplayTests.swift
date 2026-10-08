import Foundation
import OrgCore
import Testing
@testable import OrgPresentation

struct StartupDisplayTests {
    @Test func settingsApplyWithoutStartupWords() {
        let tree = OrgParser.parse("* A\n:LOGBOOK:\nx\n:END:\n#+begin_src sh\necho\n#+end_src\n")
        var options = EditingOptions.org
        options.startupIndented = false
        options.hideLeadingStars = true
        options.startupWithInlineImages = true
        options.startupAlignAllTables = true
        options.startupTruncated = true
        options.hideBlockStartup = true
        let display = Presentation.startupDisplay(tree, options: options)
        #expect(!display.indented)
        #expect(display.hideStars)
        #expect(display.inlineImages)
        #expect(display.alignTables)
        #expect(display.truncated)
        #expect(display.wrappers.map(\.kind) == [.drawer, .block])
        #expect(display.folds.wrapperFolds == Set(display.wrappers.map(\.start)))
    }

    @Test func startupWordsOverrideSettings() {
        let tree = OrgParser.parse("#+STARTUP: noindent showstars noinlineimages noalign nohidedrawers overview\n* A\n:LOGBOOK:\nx\n:END:\n** B\n")
        var options = EditingOptions.org
        options.hideLeadingStars = true
        options.startupWithInlineImages = true
        options.startupAlignAllTables = true
        let display = Presentation.startupDisplay(tree, options: options)
        #expect(!display.indented)
        #expect(!display.hideStars)
        #expect(!display.inlineImages)
        #expect(!display.alignTables)
        #expect(display.wrappers.isEmpty)
        #expect(display.folds.folds == [tree.text.utf16.count - "* A\n:LOGBOOK:\nx\n:END:\n** B\n".utf16.count])
    }

    @Test func startupWordsTurnSettingsOn() {
        let tree = OrgParser.parse("#+STARTUP: indent hidestars inlineimages align hideblocks\n#+begin_quote\nq\n#+end_quote\n")
        var options = EditingOptions.org
        options.startupIndented = false
        let display = Presentation.startupDisplay(tree, options: options)
        #expect(display.indented)
        #expect(display.hideStars)
        #expect(display.inlineImages)
        #expect(display.alignTables)
        #expect(display.wrappers.map(\.kind) == [.block])
    }

    @Test func visibilityPropertiesOnlyWithAStartupVisibility() {
        let text = "* A\n:PROPERTIES:\n:VISIBILITY: folded\n:END:\nbody\n"
        #expect(Presentation.startupDisplay(OrgParser.parse(text), options: .org).folds.folds.isEmpty)
        #expect(Presentation.startupDisplay(OrgParser.parse("#+STARTUP: showall\n" + text), options: .org).folds.folds.count == 1)
    }
}

struct HiddenMarkupTests {
    @Test func linkMarkupAlwaysEmphasisMarkersBySetting() {
        var options = EditingOptions.org
        #expect(Presentation.hidesWithMarkup(.linkMarkup, options: options))
        #expect(!Presentation.hidesWithMarkup(.markup, options: options))
        options.hideEmphasisMarkers = true
        #expect(Presentation.hidesWithMarkup(.markup, options: options))
        #expect(!Presentation.hidesWithMarkup(.bold, options: options))
    }

    @Test func leadingStarsShowUnlessIndentedOrHidden() {
        #expect(Presentation.skipsLeadingStars(.leadingStars, indented: false, hideStars: false))
        #expect(!Presentation.skipsLeadingStars(.leadingStars, indented: true, hideStars: false))
        #expect(!Presentation.skipsLeadingStars(.leadingStars, indented: false, hideStars: true))
        #expect(!Presentation.skipsLeadingStars(.heading(level: 1), indented: false, hideStars: false))
    }

    @Test func prettyRunsSkipTheRevealedLineCommentsAndBlocks() {
        let text = "\\alpha one\n# \\beta\n\\gamma\nx_{1}\n" as NSString
        let lines = [0, 11, 19, 26]
        let all = Presentation.prettyRuns(text, in: 0..<text.length, revealedLine: nil, inBlock: { _ in false }, scriptExclusions: [], subSuperscriptsNeedBraces: true)
        #expect(all.map(\.lineStart) == [lines[0], lines[2], lines[3]])
        let revealed = Presentation.prettyRuns(text, in: 0..<text.length, revealedLine: lines[2], inBlock: { $0 == lines[0] }, scriptExclusions: [], subSuperscriptsNeedBraces: true)
        #expect(revealed.map(\.lineStart) == [lines[3]])
        let excluded = Presentation.prettyRuns(text, in: 0..<text.length, revealedLine: nil, inBlock: { _ in false }, scriptExclusions: [lines[3]..<lines[3] + 5], subSuperscriptsNeedBraces: true)
        #expect(excluded.map(\.lineStart) == [lines[0], lines[2]])
    }
}

struct LineIndentTests {
    @Test(arguments: [
        ("plain", 0), ("  indented", 2), ("- item", 2), ("  - [X] done", 8), ("12. step", 4),
        ("* heading-like", 0), ("  * starred item", 4), ("-not a bullet", 0), ("\t- tab", 10),
    ])
    func hangingColumns(line: String, expected: Int) {
        #expect(Presentation.hangingColumns(line) == expected)
    }

    @Test func bodyLinesHangUnderTheirText() {
        let text = "** H\n- item\nplain\n"
        let tree = OrgParser.parse(text)
        let indents = Presentation.lineIndents(tree, in: 0..<text.utf16.count)
        #expect(indents.map(\.range) == [0..<5, 5..<12, 12..<18])
        #expect(indents.map(\.firstLine) == [0, 3, 3])
        #expect(indents.map(\.wrapped) == [3, 5, 3])
    }
}
