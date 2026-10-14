import Foundation
import PDFKit
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// PDF from the HTML export, laid out and paginated by WebKit as printing does: no Emacs or TeX.
@MainActor
public enum PDFExport {
    /// US Letter where it's the custom, A4 elsewhere.
    nonisolated static func usesLetter(_ region: String? = Locale.current.region?.identifier) -> Bool {
        ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR"].contains(region ?? "")
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The page's margins in points, a font family for the text (empty: the export's own), and
    /// whether pages are numbered.
    public struct Options: Sendable, Equatable {
        public var margin: Int
        public var font: String
        public var pageNumbers: Bool
        public init(margin: Int = 50, font: String = "", pageNumbers: Bool = true) {
            self.margin = margin
            self.font = font
            self.pageNumbers = pageNumbers
        }
    }

    /// `printCSS` with the body font, when one is set.
    static func css(_ options: Options) -> String {
        guard !options.font.isEmpty else { return printCSS }
        let family = options.font.replacingOccurrences(of: "\"", with: "")
        return printCSS.replacingOccurrences(of: "</style>", with: "body { font-family: \"\(family)\", -apple-system, sans-serif; }\n</style>")
    }

    /// Each page's number, centred in its bottom margin, as an annotation: drawing it into the
    /// page would mean drawing the page again and losing WebKit's links.
    static func numberPages(_ data: Data, margin: Int) -> Data {
        guard let document = PDFDocument(data: data) else { return data }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            let height: CGFloat = 14
            let bottom = box.minY + max(4, (CGFloat(margin) - height) / 2)
            let note = PDFAnnotation(bounds: CGRect(x: box.midX - 40, y: bottom, width: 80, height: height), forType: .freeText, withProperties: nil)
            note.contents = String(index + 1)
            note.font = .systemFont(ofSize: 9)
            note.fontColor = .gray
            note.color = .clear
            note.alignment = .center
            let border = PDFBorder()
            border.lineWidth = 0
            note.border = border
            note.isReadOnly = true
            page.addAnnotation(note)
        }
        return document.dataRepresentation() ?? data
    }

    /// Rules added for paper: the page's own width, light colors, and no breaks inside code,
    /// tables and figures or right after a heading.
    static let printCSS = """
        <style media="all">
        :root { color-scheme: light; }
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        body { max-width: none; margin: 0; padding: 0; font-size: 11pt; background: #fff; color: #222; }
        pre, table, figure, blockquote, .figure { break-inside: avoid; }
        h1, h2, h3, h4, h5, h6 { break-after: avoid; }
        pre { white-space: pre-wrap; overflow-wrap: anywhere; }
        </style>
        """

    /// The page `html` (an `HTMLExport.page`) as a PDF. `directory` is the Org file's folder,
    /// where relative image links are read from.
    public static func pdf(html: String, directory: URL?, options: Options = Options()) async throws -> Data {
        let page = html.replacingOccurrences(of: "</head>", with: css(options) + "\n</head>")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1100))
        let loader = Loader()
        webView.navigationDelegate = loader
        #if os(macOS)
        webView.appearance = NSAppearance(named: .aqua)
        // A file beside nothing the user owns, readable with the images it links to.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("page.html")
        let based = directory.map { page.replacingOccurrences(of: "<head>", with: "<head>\n<base href=\"\($0.absoluteString)\">") } ?? page
        try based.write(to: file, atomically: true, encoding: .utf8)
        webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        #else
        webView.overrideUserInterfaceStyle = .light
        webView.loadHTMLString(page, baseURL: directory)
        #endif
        try await loader.loaded()
        // MathJax typesets after the page loads.
        _ = try? await webView.callAsyncJavaScript(
            "if (window.MathJax && MathJax.startup && MathJax.startup.promise) { await MathJax.startup.promise; }",
            contentWorld: .page
        )
        let data = try await render(webView, margin: CGFloat(max(0, options.margin)))
        return options.pageNumbers ? numberPages(data, margin: options.margin) : data
    }

    #if os(macOS)
    private static func render(_ webView: WKWebView, margin: CGFloat) async throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        // The operation runs modally for a window; this one is never shown.
        let window = NSWindow(contentRect: webView.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        let done = PrintDone()
        await withCheckedContinuation { continuation in
            done.continuation = continuation
            operation.runModal(for: window, delegate: done, didRun: #selector(PrintDone.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard done.success, let data = try? Data(contentsOf: output), !data.isEmpty else { throw Failure(description: "The PDF couldn't be made.") }
        return data
    }

    private final class PrintDone: NSObject {
        var continuation: CheckedContinuation<Void, Never>?
        var success = false

        @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            self.success = success
            continuation?.resume()
            continuation = nil
        }
    }
    #else
    private static func render(_ webView: WKWebView, margin: CGFloat) async throws -> Data {
        let letter = usesLetter()
        let paper = CGRect(x: 0, y: 0, width: letter ? 612 : 595.2, height: letter ? 792 : 841.8)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: margin, dy: margin)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        guard renderer.numberOfPages > 0 else { throw Failure(description: "The PDF couldn't be made.") }
        return data as Data
    }
    #endif

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func loaded() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        private func finish(_ result: Result<Void, Error>) {
            if let continuation {
                continuation.resume(with: result)
                self.continuation = nil
            } else {
                self.result = result
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    }
}
