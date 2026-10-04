import Testing
@testable import OrgCore

struct SemanticValueTests {
    @Test func parseHeaderArguments() {
        let pairs = HeaderArguments.parse("ignored :results output silent :dir /tmp :VAR x=1")
        #expect(pairs.map { "\($0.key)=\($0.value)" } == [":results=output silent", ":dir=/tmp", ":var=x=1"])
    }

    @Test func widths() {
        #expect(displayWidth("abc") == 3)
        #expect(displayWidth("日本") == 4)
        #expect(displayWidth("e\u{301}") == 1)
        #expect(displayWidth("😀") == 2)
    }
}
