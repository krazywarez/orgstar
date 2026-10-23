import OrgCore
import SwiftUI

/// `org-columns` laid out: a row of column titles, a rule, then a row per entry, each cell from `cell(row, column)`.
public struct ColumnViewGrid<Cell: View>: View {
    let view: ColumnView.View
    let verticalSpacing: CGFloat
    let cell: (Int, Int) -> Cell

    public init(view: ColumnView.View, verticalSpacing: CGFloat, @ViewBuilder cell: @escaping (Int, Int) -> Cell) {
        self.view = view
        self.verticalSpacing = verticalSpacing
        self.cell = cell
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: verticalSpacing) {
            GridRow {
                ForEach(view.specs.indices, id: \.self) { i in
                    Text(view.specs[i].title).bold().foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(view.rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(view.specs.indices, id: \.self) { c in cell(r, c) }
                }
            }
        }
    }
}
