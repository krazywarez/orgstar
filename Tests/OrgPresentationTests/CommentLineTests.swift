import Foundation
import Testing
@testable import OrgPresentation

struct CommentLineTests {
    @Test func matchesThePattern() {
        let lines = ["#", "# x", "#+TITLE: a", "  #\n", "\t# \n", "#x", "a # b", "", "#\r\n", "#\r", "#\u{2028}", " #+\n", "##", "  x#"]
        for line in lines {
            let expected = line.range(of: "^[ \\t]*#([ +]|$)", options: .regularExpression) != nil
            #expect(Presentation.isCommentOrKeyword(line) == expected, "\(line.debugDescription)")
        }
    }
}
