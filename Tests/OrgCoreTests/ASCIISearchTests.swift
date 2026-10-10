import Foundation
import Testing
@testable import OrgCore

struct ASCIISearchTests {
    @Test func matchesCaseInsensitiveRangeOf() {
        let texts = ["", "#+SETUPFILE: x", "a\n#+SetupFile:y", "#+setupfil", "é #+setupfile:", "##+setupfile:", "[CITE:@a]", "x[cit"]
        for text in texts {
            for needle in ["#+setupfile:", "[cite", "#+INCLUDE:"] {
                #expect(text.containsIgnoringASCIICase(needle) == (text.range(of: needle, options: .caseInsensitive) != nil), "\(text) \(needle)")
                #expect(text[...].containsIgnoringASCIICase(needle) == (text.range(of: needle, options: .caseInsensitive) != nil))
            }
        }
    }
}
