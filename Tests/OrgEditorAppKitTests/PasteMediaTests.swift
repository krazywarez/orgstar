import AppKit
import OrgDocument
import Testing
@testable import OrgEditorAppKit

@MainActor
struct PasteMediaTests {
    static func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orgstar-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    static var tiff: Data {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        return image.tiffRepresentation!
    }

    @Test func imagesWithoutTextArePastedAsImages() {
        let png = Self.pasteboard()
        png.setData(Data("PNG".utf8), forType: .png)
        #expect(OrgTextView.image(on: png)?.ext == "png")
        #expect(OrgTextView.image(on: png)?.data == Data("PNG".utf8))

        let tiff = Self.pasteboard()
        tiff.setData(Self.tiff, forType: .tiff)
        let converted = OrgTextView.image(on: tiff)
        #expect(converted?.ext == "png")
        #expect((converted.flatMap { NSBitmapImageRep(data: $0.data) }?.pixelsWide ?? 0) >= 2)

        let text = Self.pasteboard()
        text.setData(Data("PNG".utf8), forType: .png)
        text.setString("caption", forType: .string)
        #expect(OrgTextView.image(on: text) == nil)
    }

    @Test func filesAreFiles() {
        let pasteboard = Self.pasteboard()
        let url = URL(fileURLWithPath: "/tmp/a.png")
        pasteboard.writeObjects([url as NSURL])
        #expect(OrgTextView.files(on: pasteboard) == [url])
        #expect(OrgTextView.files(on: Self.pasteboard()) == nil)
    }

    @Test func theEditorTakesMediaOnlyInOrgWithAHandler() {
        let harness = Harness("* a\n")
        let view = harness.editor.textView as! OrgTextView
        let pasteboard = Self.pasteboard()
        pasteboard.setData(Data("PNG".utf8), forType: .png)
        #expect(!view.takeMedia(from: pasteboard))
        var got: (Data, String)?
        harness.editor.onImage = { got = ($0, $1) }
        #expect(view.takeMedia(from: pasteboard))
        #expect(got?.1 == "png")

        let plain = Harness(DocumentState(bytes: Array("x\n".utf8)), mode: .plain(language: nil))
        plain.editor.onImage = { _, _ in Issue.record("a plain buffer took an image") }
        #expect(!(plain.editor.textView as! OrgTextView).takeMedia(from: pasteboard))
    }
}
