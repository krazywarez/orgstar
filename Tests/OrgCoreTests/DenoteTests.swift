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
}
