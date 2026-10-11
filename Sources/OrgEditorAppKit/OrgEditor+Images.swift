#if os(macOS)
import AppKit
import OrgCore
import OrgPresentation

extension OrgEditor {
    // MARK: - Inline images

    private static let imageCache = NSCache<NSString, NSImage>()

    func toggleImages() {
        showsImages.toggle()
        refreshImages()
        if showsImages {
            let ns = textView.string as NSString
            var count = 0
            var offset = 0
            while offset < ns.length {
                let line = ns.lineRange(for: NSRange(location: offset, length: 0))
                if let image = InlineImages.image(atLine: line.location, in: ns, remote: remote), loadImage(image.path) != nil { count += 1 }
                offset = NSMaxRange(line)
            }
            onMessage?("\(count) images displayed inline")
        } else {
            onMessage?("Inline image display turned off")
        }
    }

    public func refreshImages() {
        keepingTopLine {
            restyleOutsideEditing(0..<utf16Length)
            invalidateAllLayout()
        }
        redrawViews()
    }

    /// Whether http(s) links show, as `org-display-remote-inline-images` says.
    private var remote: Bool { options.remoteInlineImages != "skip" }

    private func loadImage(_ path: String) -> NSImage? {
        if path.contains("://") {
            guard let url = URL(string: path) else { return nil }
            let mode = RemoteImages.Mode(rawValue: options.remoteInlineImages) ?? .skip
            let data = RemoteImages.shared.data(for: url, mode: mode) { [weak self] in
                guard let self, self.showsImages else { return }
                self.refreshImages()
            }
            return data.flatMap(NSImage.init(data:))
        }
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : (baseDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).appendingPathComponent(expanded)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)" as NSString
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        Self.imageCache.setObject(image, forKey: key)
        return image
    }

    /// Image lines in `range` show the image over the link, which is hidden unless the caret is
    /// on the line.
    func applyImages(_ range: Range<Int>, in storage: NSTextStorage, revealed: NSRange) {
        guard showsImages, isOrg else { return }
        let text = storage.string as NSString
        let maxWidth = max(80, (textView.textContainer?.size.width ?? 600) - 40)
        var location = range.lowerBound
        while location < range.upperBound, location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            guard let image = InlineImages.image(atLine: line.location, in: text, remote: remote), let picture = loadImage(image.path) else { continue }
            var width = image.width.map(CGFloat.init) ?? picture.size.width
            width = min(width, maxWidth)
            let height = picture.size.width > 0 ? width * picture.size.height / picture.size.width : 0
            let content = NSRange(location: line.location, length: line.length - (text.substring(with: line).hasSuffix("\n") ? 1 : 0))
            // Invisible, keeping the line's height, so line numbers stay apart.
            if line.location != revealed.location, content.length > 0 {
                storage.addAttributes([.foregroundColor: NSColor.clear, .underlineStyle: 0], range: content)
            }
            storage.addAttribute(.orgImage, value: InlineImageBox(image: picture, size: CGSize(width: width, height: height)), range: NSRange(location: line.location, length: max(1, content.length)))
            let style = (storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            // The image sits where the line is; the spacing makes room for the rest of it.
            style.paragraphSpacing = max(0, height + 4 - theme.font.boundingRectForFont.height)
            storage.addAttribute(.paragraphStyle, value: style, range: line)
        }
    }
}
#endif
