import Foundation
import Testing
@testable import OrgCore

struct DenoteTests {
    @Test func readsIdentifiersFromFileNames() {
        #expect(Denote.identifier(ofFile: "/n/20261119T120000--a-note__kw1_kw2.org") == "20261119T120000")
        #expect(Denote.identifier(ofFile: "20261119T120000.org") == "20261119T120000")
        #expect(Denote.identifier(ofFile: "20261119T120000==1a--title.org") == "20261119T120000")
        #expect(Denote.identifier(ofFile: "--a-note@@20261119T120000__kw.org") == "20261119T120000")
        #expect(Denote.identifier(ofFile: "a-note.org") == nil)
        #expect(Denote.identifier(ofFile: "20261119-diary.org") == nil)
    }

    @Test func splitsSearchOptions() {
        #expect(Denote.split("20261119T120000") == ("20261119T120000", nil))
        #expect(Denote.split("20261119T120000::#h") == ("20261119T120000", "#h"))
    }

    @Test func prefersOrgFiles() {
        let paths = ["/n/20261119T120000--a.pdf", "/n/20261119T120000--a.org", "/n/20261119T120001--b.org"]
        #expect(Denote.file(withIdentifier: "20261119T120000", in: paths) == "/n/20261119T120000--a.org")
        #expect(Denote.file(withIdentifier: "20261119T120002", in: paths) == nil)
    }

    /// 2026-11-19 09:05:03, a Thursday, in UTC.
    static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    static let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 9, minute: 5, second: 3))!

    @Test func namesNewFiles() {
        #expect(Denote.slug("Hello, World: a_test -- Note!") == "hello-world-a-test-note")
        #expect(Denote.slug("  Café au lait  ") == "café-au-lait")
        #expect(Denote.keywords(["Emacs", "org-mode", "emacs", "", "two words"]) == ["emacs", "orgmode", "twowords"])
        let id = Denote.identifier(for: Self.date, calendar: Self.calendar)
        #expect(id == "20261119T090503")
        #expect(Denote.fileName(identifier: id, title: "A note", keywords: ["b", "a"]) == "20261119T090503--a-note__b_a.org")
        #expect(Denote.fileName(identifier: id, signature: "1a", title: "", keywords: []) == "20261119T090503==1a.org")
        #expect(Denote.frontMatter(title: "A note", date: Self.date, keywords: ["a", "b"], identifier: id, calendar: Self.calendar) == """
            #+title:      A note
            #+date:       [2026-11-19 Thu 09:05]
            #+filetags:   :a:b:
            #+identifier: 20261119T090503


            """)
    }

    @Test func readsNamesInAnyOrder() {
        #expect(Denote.name(ofFile: "/n/20261119T090503==1a--a-note__kw1_kw2.org")
            == Denote.Name(identifier: "20261119T090503", signature: "1a", title: "a-note", keywords: ["kw1", "kw2"], ext: "org"))
        #expect(Denote.name(ofFile: "--a-note__kw@@20261119T090503.pdf")
            == Denote.Name(identifier: "20261119T090503", signature: nil, title: "a-note", keywords: ["kw"], ext: "pdf"))
    }

    @Test func renamesFromFrontMatter() {
        let text = "#+title:      New Title\n#+filetags:   :Zeta:alpha:\n#+identifier: 20261119T090503\n\nBody\n"
        #expect(Denote.renamed("/n/20261119T090503==1a--old__x.org", text: text) == "/n/20261119T090503==1a--new-title__alpha_zeta.org")
        #expect(Denote.renamed("/n/plain.org", text: text) == "/n/20261119T090503--new-title__alpha_zeta.org")
        #expect(Denote.renamed("/n/plain.org", text: "#+title: x\n") == nil)
        #expect(Denote.renamed("/n/20261119T090503--old-name__x.org", text: "No front matter\n") == "/n/20261119T090503--old-name__x.org")
    }
}
