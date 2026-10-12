#if os(macOS)
import AppKit

/// Images and files pasted or dropped on the text view, for `yank-media` and Org's
/// drag-and-drop handlers. Text goes to the text system as before.
extension OrgTextView {
    static let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    static let gif = NSPasteboard.PasteboardType("com.compuserve.gif")

    /// The files on `pasteboard`, if it has any.
    static func files(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : urls
    }

    /// The image on `pasteboard` and the extension for it, when there is no text: PNG, JPEG
    /// and GIF as they are, anything else AppKit reads as PNG.
    static func image(on pasteboard: NSPasteboard) -> (data: Data, ext: String)? {
        guard pasteboard.availableType(from: [.string]) == nil else { return nil }
        if let data = pasteboard.data(forType: .png) { return (data, "png") }
        if let data = pasteboard.data(forType: jpeg) { return (data, "jpeg") }
        if let data = pasteboard.data(forType: gif) { return (data, "gif") }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        return (png, "png")
    }

    /// Hands files or an image to the editor; false when it doesn't take them.
    func takeMedia(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable else { return false }
        if let files = Self.files(on: pasteboard) { return onFiles?(files) ?? false }
        if let image = Self.image(on: pasteboard) { return onImage?(image.data, image.ext) ?? false }
        return false
    }

    override func paste(_ sender: Any?) {
        if !takeMedia(from: OrgEditor.pasteboard) { super.paste(sender) }
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff, Self.jpeg, Self.gif]
    }

    override func dragOperation(for dragInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        if isEditable, Self.files(on: dragInfo.draggingPasteboard) != nil || Self.image(on: dragInfo.draggingPasteboard) != nil { return .copy }
        return super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard isEditable, Self.files(on: pasteboard) != nil || Self.image(on: pasteboard) != nil else {
            return super.performDragOperation(sender)
        }
        window?.makeFirstResponder(self)
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        return takeMedia(from: pasteboard)
    }
}
#endif
