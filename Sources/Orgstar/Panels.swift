import Foundation
import OrgCore

enum Panel: Identifiable {
    case columns(UUID, ColumnView.View)
    case export(UUID, URL)
    case conflict(UUID)
    case syncCopies(UUID)
    case recovery(UUID)
    /// A `#+PLOT` table drawn here, or gnuplot's image of it.
    case plot(UUID, TablePlot.Plot)
    case plotImage(UUID, URL)

    var id: UUID {
        switch self {
        case .columns(let id, _), .export(let id, _), .conflict(let id), .syncCopies(let id), .recovery(let id), .plot(let id, _), .plotImage(let id, _): id
        }
    }
}

struct BlockEditRequest: Identifiable {
    let id = UUID()
    let edit: BlockEdit
}
