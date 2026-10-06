import OrgCore
import SwiftUI

/// `org-columns`, read-only: one row per entry, one column per column-format field, with
/// summaries. Clicking a row goes to its heading.
struct ColumnViewSheet: View {
    let view: ColumnView.View
    let jump: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Column View").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(view.specs.indices, id: \.self) { i in
                            Text(view.specs[i].title).bold().foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    ForEach(view.rows.indices, id: \.self) { r in
                        let row = view.rows[r]
                        GridRow {
                            ForEach(view.specs.indices, id: \.self) { i in
                                Text(cell(row, i))
                                    .lineLimit(1)
                                    .frame(maxWidth: view.specs[i].width.map { CGFloat($0) * 8.5 }, alignment: .leading)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            jump(row.start)
                            dismiss()
                        }
                    }
                }
                .font(.system(.body, design: .monospaced))
                .padding(10)
            }
            .defaultScrollAnchor(.topLeading)
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    /// ITEM with the heading's stars, as org shows it.
    private func cell(_ row: ColumnView.Row, _ i: Int) -> String {
        guard view.specs[i].property == "ITEM" else { return row.values[i] }
        return String(repeating: "*", count: row.level) + " " + row.values[i]
    }
}
