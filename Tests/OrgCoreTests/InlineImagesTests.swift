import Foundation
import Testing
@testable import OrgCore

struct InlineImagesTests {
    @Test func findsImageLines() {
        let text = "#+STARTUP: inlineimages\n* Images\n[[file:pic.png]]\n#+NAME: x\n#+ATTR_ORG: :width 60\n[[./pic.png]]\n[[pic.png][desc]]\nAfter [[pic.png]] text\n[[https://x.org/a.png]]\n" as NSString
        func at(_ s: String) -> InlineImages.Image? { InlineImages.image(atLine: text.range(of: s).location, in: text) }
        #expect(at("[[file:pic") == InlineImages.Image(path: "pic.png", width: nil))
        #expect(at("[[./pic") == InlineImages.Image(path: "./pic.png", width: 60))
        #expect(at("[[pic.png][") == nil && at("After") == nil && at("[[https") == nil)
        #expect(InlineImages.startup(OrgParser.parse(text as String)) == true)
        #expect(InlineImages.startup(OrgParser.parse("#+STARTUP: overview noinlineimages\n")) == false)
        #expect(InlineImages.startup(OrgParser.parse("* x\n")) == nil)
    }
}
