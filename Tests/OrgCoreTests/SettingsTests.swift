import Testing
@testable import OrgCore

struct SettingsTests {
    func scan(_ text: String, blockEnds: [Int: Int] = [:]) -> OrgSettings {
        let lines = splitRawLines(text)
        let info = lines.map { classifyLine($0.content) }
        return SettingsScanner.scan(lines: lines, info: info, blockEnds: blockEnds, defaults: .default)
    }

    @Test func defaultsWithoutKeywords() {
        let settings = scan("* TODO a\n")
        #expect(settings.todoKeywordNames == ["TODO", "DONE"])
        #expect(settings.isDone("DONE"))
    }

    @Test func fileKeywordsReplaceDefaults() {
        let settings = scan("#+TODO: NEXT(n) WAIT(w@/!) | DONE(d!) CANCELED(c@)\n")
        #expect(settings.todoKeywordNames == ["NEXT", "WAIT", "DONE", "CANCELED"])
        let sequence = settings.todoSequences[0]
        #expect(sequence.active.map(\.name) == ["NEXT", "WAIT"])
        #expect(sequence.done.map(\.name) == ["DONE", "CANCELED"])
        #expect(sequence.active[1] == TodoKeyword(name: "WAIT", fastKey: "w", logOnEnter: "@", logOnLeave: "!"))
        #expect(sequence.done[0] == TodoKeyword(name: "DONE", fastKey: "d", logOnEnter: "!", logOnLeave: nil))
    }

    @Test func lastWordIsDoneWithoutSeparator() {
        let settings = scan("#+SEQ_TODO: A B C\n")
        #expect(settings.todoSequences[0].active.map(\.name) == ["A", "B"])
        #expect(settings.todoSequences[0].done.map(\.name) == ["C"])
    }

    @Test func severalLinesMakeSeveralSequences() {
        let settings = scan("#+TODO: A | B\n#+TYP_TODO: X | Y\n")
        #expect(settings.todoSequences.count == 2)
        #expect(settings.todoSequences.map(\.kind) == [.type, .sequence])
    }

    @Test func keywordsInsideBlocksAreIgnored() {
        let text = "#+begin_example\n#+TODO: X | Y\n#+end_example\n"
        #expect(scan(text, blockEnds: [0: 2]).todoKeywordNames == ["TODO", "DONE"])
    }

    @Test func priorities() {
        #expect(scan("#+PRIORITIES: 1 10 5\n").priorities == Priorities(highest: "1", lowest: "10", default: "5"))
        #expect(scan("").priorities == Priorities(highest: "A", lowest: "C", default: "B"))
    }
}
