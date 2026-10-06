import Testing
@testable import OrgCore

struct BacklinkTests {
    let heading = Backlinks.Target(path: "/notes/a.org", title: "Fix the sink [1/2]", id: "abc-1", customID: "sink")
    let file = Backlinks.Target(path: "/notes/a.org")

    @Test func followsLinksAsOrgDoes() {
        func links(_ link: String, from source: String = "/notes/b.org", to target: Backlinks.Target) -> Bool {
            Backlinks.links(link, from: source, to: target, home: "/home")
        }
        #expect(links("id:abc-1", to: heading) && !links("id:abc-2", to: heading) && !links("id:abc-1", to: file))
        #expect(links("file:a.org::*Fix the sink", to: heading))
        #expect(links("file:./a.org::#sink", to: heading))
        #expect(links("file:/notes/a.org", to: file) && !links("file:/notes/a.org", to: heading))
        #expect(links("./a.org", to: file) && links("../notes/a.org::*Fix the sink", to: heading))
        #expect(links("file:sub/../a.org", to: file))
        #expect(!links("file:c.org::*Fix the sink", to: heading) && !links("https://a.org", to: file))
        #expect(links("~/x.org", from: "/notes/b.org", to: Backlinks.Target(path: "/home/x.org")))
        // Within the file.
        #expect(links("*Fix the sink", from: "/notes/a.org", to: heading) && links("#sink", from: "/notes/a.org", to: heading))
        #expect(links("Fix the sink", from: "/notes/a.org", to: heading))
        #expect(!links("*Fix the sink", from: "/notes/b.org", to: heading))
    }
}
