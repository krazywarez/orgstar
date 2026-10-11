import CoreGraphics
import Foundation
import OrgCore
import SwiftMath
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// `org-latex-preview`: LaTeX fragments and environments drawn as typeset math, by SwiftMath
/// rather than LaTeX, so it works without TeX and on iOS.
public enum LatexPreview {
    /// A fragment or environment and what to typeset.
    public struct Fragment: Equatable, Sendable {
        public let range: Range<Int>
        public let latex: String
        /// `$$…$$`, `\[…\]` and environments: display style.
        public let display: Bool
        /// A LaTeX environment, which takes lines of its own.
        public let environment: Bool
    }

    /// The fragments and environments that overlap `range`.
    public static func fragments(_ tree: OrgTree, in range: Range<Int>) -> [Fragment] {
        var out: [Fragment] = []
        func walk(_ node: SyntaxNode) {
            guard node.range.overlaps(range) || node.range.isEmpty && range.contains(node.range.lowerBound) else { return }
            switch node.kind {
            case .latexFragment:
                if let fragment = fragment(node.text, range: node.range) { out.append(fragment) }
            case .latexEnvironment:
                let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let leading = node.text.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let end = node.range.lowerBound + leading + (text as NSString).length
                out.append(Fragment(range: (node.range.lowerBound + leading)..<end, latex: environment(text), display: true, environment: true))
            case .block:
                return
            default:
                for child in node.children { walk(child) }
            }
        }
        walk(tree.root)
        return out
    }

    /// A fragment's math without its delimiters.
    static func fragment(_ text: String, range: Range<Int>) -> Fragment? {
        let pairs: [(String, String, Bool)] = [("$$", "$$", true), ("\\[", "\\]", true), ("\\(", "\\)", false), ("$", "$", false)]
        for (open, close, display) in pairs where text.hasPrefix(open) && text.hasSuffix(close) && text.count >= open.count + close.count {
            let inner = String(text.dropFirst(open.count).dropLast(close.count))
            guard inner.contains(where: { !$0.isWhitespace }) else { return nil }
            return Fragment(range: range, latex: inner, display: display, environment: false)
        }
        // `\command[…]{…}`.
        return Fragment(range: range, latex: text, display: false, environment: false)
    }

    /// An environment as SwiftMath reads it: `equation` and `displaymath` as their body,
    /// `align` and `gather` as `aligned` and `gathered`.
    static func environment(_ text: String) -> String {
        guard let m = text.firstMatch(of: #/(?s)^\\begin\{([A-Za-z]+)\*?\}(.*)\\end\{\1\*?\}$/#) else { return text }
        let body = String(m.2).trimmingCharacters(in: .whitespacesAndNewlines)
        switch m.1 {
        case "equation", "displaymath", "math": return body
        case "align", "alignat", "flalign", "eqnarray": return "\\begin{aligned}" + body + "\\end{aligned}"
        case "gather", "multline": return "\\begin{gathered}" + body + "\\end{gathered}"
        default: return text
        }
    }

    /// Typeset math: the image at the screen's scale, its size in points, and how far it
    /// reaches above and below the baseline.
    public struct Rendering: @unchecked Sendable {
        public let image: CGImage
        public let size: CGSize
        public let ascent: CGFloat
        public let descent: CGFloat
    }

    #if os(macOS)
    public typealias Color = NSColor
    #else
    public typealias Color = UIColor
    #endif

    private final class Box: NSObject {
        let rendering: Rendering?
        init(_ rendering: Rendering?) { self.rendering = rendering }
    }

    nonisolated(unsafe) private static let cache = NSCache<NSString, Box>()

    /// `latex` typeset at `fontSize` in `color`, or nil when SwiftMath can't read it.
    @MainActor
    public static func render(_ latex: String, display: Bool, fontSize: CGFloat, color: Color, scale: CGFloat) -> Rendering? {
        let key = "\(display)|\(fontSize)|\(scale)|\(color.description)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached.rendering }
        var math = MathImage(latex: latex, fontSize: fontSize, textColor: color, labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        var rendering: Rendering?
        if error == nil, let image, let layout, let cg = cgImage(image, scale: scale) {
            rendering = Rendering(image: cg, size: image.size, ascent: layout.ascent, descent: layout.descent)
        }
        cache.setObject(Box(rendering), forKey: key)
        return rendering
    }

    #if os(macOS)
    private static func cgImage(_ image: NSImage, scale: CGFloat) -> CGImage? {
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
    #else
    private static func cgImage(_ image: UIImage, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }
    #endif
}

extension Presentation {
    /// `#+STARTUP: latexpreview` and `nolatexpreview`, last one wins; nil without either.
    public static func startupLatexPreview(_ tree: OrgTree) -> Bool? {
        var shows: Bool?
        for word in startupOptions(tree).map({ $0.lowercased() }) {
            if word == "latexpreview" { shows = true } else if word == "nolatexpreview" { shows = false }
        }
        return shows
    }
}
