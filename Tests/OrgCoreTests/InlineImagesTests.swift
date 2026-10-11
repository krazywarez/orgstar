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
        #expect(InlineImages.startup(OrgParser.parse("#+begin_src org\n#+STARTUP: inlineimages\n#+end_src\n")) == nil)
    }

    @Test func attachmentLinksNeedTheResolver() {
        let text = "* Photo\n[[attachment:cat.jpg]]\n#+ATTR_ORG: :width 80\n[[attachment:sub/dog.png]]\n[[attachment:cat.jpg][desc]]\n" as NSString
        func at(_ s: String, _ resolve: ((String, Int) -> String?)?) -> InlineImages.Image? {
            InlineImages.image(atLine: text.range(of: s).location, in: text, attachment: resolve)
        }
        #expect(at("[[attachment:cat.jpg]]", nil) == nil)
        var asked: [(String, Int)] = []
        let resolve: (String, Int) -> String? = { name, offset in
            asked.append((name, offset))
            return "/notes/data/ab/cd/" + name
        }
        #expect(at("[[attachment:cat.jpg]]", resolve) == InlineImages.Image(path: "/notes/data/ab/cd/cat.jpg", width: nil))
        #expect(at("[[attachment:sub", resolve) == InlineImages.Image(path: "/notes/data/ab/cd/sub/dog.png", width: 80))
        #expect(at("[[attachment:cat.jpg][", resolve) == nil)
        #expect(asked.map(\.0) == ["cat.jpg", "sub/dog.png"] && asked[0].1 == text.range(of: "[[attachment:cat.jpg]]").location)
        #expect(at("[[attachment:cat.jpg]]", { _, _ in nil }) == nil)
    }
}
