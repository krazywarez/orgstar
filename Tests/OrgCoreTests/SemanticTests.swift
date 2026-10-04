import Testing
@testable import OrgCore

func model(_ text: String, _ settings: SemanticSettings = .default) -> DocumentModel {
    DocumentModel(tree: OrgParser.parse(text), settings: settings)
}

struct HeadingInfoTests {
    @Test func basics() {
        let m = model("* TODO [#A] Write *plan* :work:\n** DONE Sub\n")
        #expect(m.headings.count == 2)
        let top = m.headings[0]
        #expect(top.level == 1)
        #expect(top.todo == "TODO")
        #expect(!top.isDone)
        #expect(top.priority == "A")
        #expect(top.title == "Write *plan*")
        #expect(top.localTags == ["work"])
        #expect(top.parent == nil)
        #expect(m.headings[1].parent == 0)
        #expect(m.headings[1].isDone)
        #expect(m.outlinePath(of: 1) == ["Write *plan*", "Sub"])
    }

    @Test func planningPropertiesClocksAndBody() throws {
        let text = """
        * a
        SCHEDULED: <2026-10-04 Sun> DEADLINE: <2026-10-10 Sat -2d>
        :PROPERTIES:
        :ID: abc
        :Effort: 1:00
        :END:
        :LOGBOOK:
        CLOCK: [2026-10-04 Sun 10:00]--[2026-10-04 Sun 11:30] =>  1:30
        CLOCK: [2026-10-05 Mon 09:00]
        :END:
        See <2026-10-07 Wed> and [[https://a.b][x]].

        """
        let h = model(text).headings[0]
        #expect(h.scheduled?.start.day == 4)
        #expect(h.deadline?.warning?.interval.value == 2)
        #expect(h.closed == nil)
        #expect(h.id == "abc")
        #expect(h.properties == [Property(key: "ID", value: "abc"), Property(key: "Effort", value: "1:00")])
        #expect(h.clocks.count == 2)
        #expect(h.clocks[0].minutes == 90)
        #expect(h.clocks[0].end?.hour == 11)
        #expect(h.clocks[1].end == nil)
        #expect(h.timestamps == [try #require(Timestamp.parse("<2026-10-07 Wed>"))])
        #expect(h.links == ["https://a.b"])
    }

    @Test func childContentStaysWithChild() {
        let m = model("* a\n** b\n<2026-10-04 Sun>\n")
        #expect(m.headings[0].timestamps.isEmpty)
        #expect(m.headings[1].timestamps.count == 1)
    }

    @Test func titleTimestampsAndLinks() {
        let h = model("* Call <2026-10-04 Sun> [[id:x][y]]\n").headings[0]
        #expect(h.timestamps.count == 1)
        #expect(h.links == ["id:x"])
    }

    @Test func doneStatesComeFromFileSettings() {
        let m = model("#+TODO: NEXT | SHIPPED\n* SHIPPED x\n")
        #expect(m.headings[0].isDone)
    }
}

struct InheritanceTests {
    @Test func tagInheritance() {
        let text = "#+FILETAGS: :f:\n* a :x:noinherit:\n** b :y:\n"
        let m = model(text, SemanticSettings(tagsExcludedFromInheritance: ["noinherit"]))
        #expect(m.tags(of: 1).map(\.value) == ["f", "x", "y"])
        #expect(m.tags(of: 1).map(\.source) == [.file, .heading(0), .heading(1)])
        #expect(model(text, SemanticSettings(tagInheritance: false)).tags(of: 1).map(\.value) == ["y"])
    }

    @Test func ownTagWinsOverInherited() {
        #expect(model("* a :x:\n** b :x:\n").tags(of: 1) == [Resolved("x", .heading(1))])
    }

    @Test func propertyPolicies() {
        let text = "#+PROPERTY: owner team\n* a\n:PROPERTIES:\n:OWNER: alice\n:CATEGORY: work\n:ID: p\n:END:\n** b\n"
        let plain = model(text)
        #expect(plain.property("OWNER", of: 1) == nil)
        #expect(plain.property("CATEGORY", of: 1) == Resolved("work", .heading(0)))
        #expect(plain.property("OWNER", of: nil) == Resolved("team", .file))

        let all = model(text, SemanticSettings(propertyInheritance: .all))
        #expect(all.property("owner", of: 1) == Resolved("alice", .heading(0)))
        #expect(all.property("ID", of: 1) == nil)

        let some = model(text, SemanticSettings(propertyInheritance: .only(["OWNER"])))
        #expect(some.property("OWNER", of: 1) == Resolved("alice", .heading(0)))
    }

    @Test func additiveProperties() {
        let text = "* a\n:PROPERTIES:\n:VAR: x=1\n:END:\n** b\n:PROPERTIES:\n:VAR+: y=2\n:END:\n"
        #expect(model(text, SemanticSettings(propertyInheritance: .all)).property("VAR", of: 1) == Resolved("x=1 y=2", .heading(1)))
        #expect(model(text).property("VAR", of: 1) == Resolved("y=2", .heading(1)))
    }
}

struct SrcBlockTests {
    @Test func resolution() throws {
        let text = """
        #+PROPERTY: header-args :dir /a :cache yes
        #+PROPERTY: header-args:sh :results output
        * a
        :PROPERTIES:
        :header-args+: :dir /b
        :END:
        #+NAME: hello
        #+HEADER: :var x=1
        #+begin_src sh -n :results silent
        echo $x
        #+end_src

        """
        let block = try #require(model(text).srcBlocks.first)
        #expect(block.name == "hello")
        #expect(block.language == "sh")
        #expect(block.switches == ["-n"])
        #expect(block.body == "echo $x\n")
        #expect(block.heading == 0)
        #expect(block.headerArguments[":dir"] == Resolved("/b", .heading(0)))
        #expect(block.headerArguments[":cache"] == Resolved("yes", .file))
        #expect(block.headerArguments[":results"] == Resolved("silent", .element))
        #expect(block.headerArguments[":var"] == Resolved("x=1", .element))
        #expect(block.headerArguments[":exports"] == Resolved("code", .defaults))
    }

    @Test func plainPropertyReplacesInheritedHeaderArguments() {
        let text = "#+PROPERTY: header-args :dir /a\n* a\n:PROPERTIES:\n:header-args: :cache yes\n:END:\n#+begin_src sh\n#+end_src\n"
        let block = model(text).srcBlocks[0]
        #expect(block.headerArguments[":dir"] == nil)
        #expect(block.headerArguments[":cache"] == Resolved("yes", .heading(0)))
    }

    @Test func blankLineDetachesAffiliatedKeywords() {
        #expect(model("#+NAME: x\n\n#+begin_src sh\n#+end_src\n").srcBlocks[0].name == nil)
    }

    @Test func otherBlocksAreNotSourceBlocks() {
        #expect(model("#+begin_example\nx\n#+end_example\n").srcBlocks.isEmpty)
    }
}

struct TableModelTests {
    @Test func rowsFormulasAndWidths() {
        let table = model("| a | 日本 |\n|---+---|\n| 😀 | b |\n#+TBLFM: $2=$1\n").tables[0]
        #expect(table.rows == [.cells(["a", "日本"]), .rule, .cells(["😀", "b"])])
        #expect(table.formulas == ["$2=$1"])
        #expect(table.columnWidths == [2, 4])
    }
}
