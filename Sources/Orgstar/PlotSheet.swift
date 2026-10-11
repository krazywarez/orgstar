import AppKit
import OrgApp
import OrgCore
import SwiftUI

/// A plotted table: drawn by Swift Charts, or the image gnuplot made.
struct PlotSheet: View {
    enum Content {
        case chart(TablePlot.Plot)
        case image(URL)
    }

    let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            switch content {
            case .chart(let plot):
                PlotChart(plot)
            case .image(let url):
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().padding()
                } else {
                    Text("gnuplot made no image").foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}
