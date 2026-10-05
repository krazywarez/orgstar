import AppKit
import Quartz
import SwiftUI

/// A file that isn't text: Quick Look's preview, and buttons to open it elsewhere.
struct FilePreview: View {
    let path: String

    var body: some View {
        QuickLookView(url: URL(fileURLWithPath: path))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button("Open with Default App") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Spacer()
                }
                .padding(8)
                .background(.bar)
            }
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
    }
}
