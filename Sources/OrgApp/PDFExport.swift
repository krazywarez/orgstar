import Foundation
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// PDF from the HTML export, laid out and paginated by WebKit as printing does: no Emacs or TeX.
@MainActor
public enum PDFExport {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
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
    public static func pdf(html: String, directory: URL?) async throws -> Data {
        let page = html.replacingOccurrences(of: "</head>", with: printCSS + "\n</head>")
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
        return try await render(webView)
    }

    #if os(macOS)
    private static func render(_ webView: WKWebView) async throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        info.topMargin = 50
        info.bottomMargin = 50
        info.leftMargin = 50
        info.rightMargin = 50
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
    private static func render(_ webView: WKWebView) async throws -> Data {
        // US Letter where it's the custom, A4 elsewhere.
        let letter = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR"].contains(Locale.current.region?.identifier ?? "")
        let paper = CGRect(x: 0, y: 0, width: letter ? 612 : 595.2, height: letter ? 792 : 841.8)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 50, dy: 50)), forKey: "printableRect")
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
