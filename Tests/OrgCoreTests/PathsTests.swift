import Foundation
import Testing
@testable import OrgCore

struct PathsTests {
    /// Unsandboxed, the real home folder is the one Foundation gives.
    @Test func homeIsFoundationsOutsideTheSandbox() {
        #expect(OrgPaths.home == NSHomeDirectory())
        #expect(OrgPaths.expandingTilde("~/org/a.org") == ("~/org/a.org" as NSString).expandingTildeInPath)
    }

    @Test func tildeExpandsToTheGivenHome() {
        let home = "/Users/someone"
        #expect(OrgPaths.expandingTilde("~", home: home) == home)
        #expect(OrgPaths.expandingTilde("~/", home: home) == home)
        #expect(OrgPaths.expandingTilde("~/org//notes/", home: home) == "/Users/someone/org/notes")
        #expect(OrgPaths.expandingTilde("/srv/org/", home: home) == "/srv/org")
        #expect(OrgPaths.expandingTilde("org/a.org", home: home) == "org/a.org")
        #expect(OrgPaths.expandingTilde("~~", home: home) == "~~")
        #expect(OrgPaths.expandingTilde("", home: home) == "")
    }

    @Test func otherUsersHomesAreFoundations() {
        #expect(OrgPaths.expandingTilde("~root/x", home: "/Users/someone") == ("~root/x" as NSString).expandingTildeInPath)
    }

    @Test func abbreviatesTheGivenHome() {
        let home = "/Users/someone"
        #expect(OrgPaths.abbreviatingWithTilde("/Users/someone", home: home) == "~")
        #expect(OrgPaths.abbreviatingWithTilde("/Users/someone/", home: home) == "~")
        #expect(OrgPaths.abbreviatingWithTilde("/Users/someone/org//a.org", home: home) == "~/org/a.org")
        #expect(OrgPaths.abbreviatingWithTilde("/Users/someoneelse/a.org", home: home) == "/Users/someoneelse/a.org")
        #expect(OrgPaths.abbreviatingWithTilde("~/a.org", home: home) == "~/a.org")
    }

    @Test func abbreviatingMatchesFoundationOutsideTheSandbox() {
        for path in [NSHomeDirectory(), NSHomeDirectory() + "/org//a.org/", "/tmp/a.org", "relative/a"] {
            #expect(OrgPaths.abbreviatingWithTilde(path) == (path as NSString).abbreviatingWithTildeInPath)
        }
    }
}
