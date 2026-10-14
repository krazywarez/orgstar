import Foundation
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

    @Test func contextLineShowsLinksAsTheyRead() throws {
        let body = ":PROPERTIES:\n:ID: x\n:END:\nFirst line.\nSee [[id:s-1][the sink]] and [[file:a.org]] today.\n"
        let context = try #require(Backlinks.context(in: body, link: "id:s-1"))
        #expect(context.text == "See the sink and file:a.org today.")
        #expect((context.text as NSString).substring(with: NSRange(context.link)) == "the sink")
        let plain = try #require(Backlinks.context(in: "Read [[file:a.org::*Sink]].\n", link: "file:a.org::*Sink"))
        #expect(plain.text == "Read file:a.org::*Sink." && plain.link == 5..<22)
        #expect(Backlinks.context(in: "nothing here\n", link: "id:zz") == nil)
        // A long line keeps the part around the link.
        let long = String(repeating: "word ", count: 60) + "[[id:q][target]]" + String(repeating: " more", count: 60)
        let cut = try #require(Backlinks.context(in: long, link: "id:q"))
        #expect(cut.text.utf16.count < 200 && cut.text.hasPrefix("…") && cut.text.hasSuffix("…"))
        #expect((cut.text as NSString).substring(with: NSRange(cut.link)) == "target")
    }
}
