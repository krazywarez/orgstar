import Foundation
import OrgCore

enum Panel: Identifiable {
    case columns(UUID, ColumnView.View)
    case export(UUID, URL)
    case conflict(UUID)
    case syncCopies(UUID)
    case recovery(UUID)

    var id: UUID {
        switch self {
        case .columns(let id, _), .export(let id, _), .conflict(let id), .syncCopies(let id), .recovery(let id): id
        }
    }
}

struct BlockEditRequest: Identifiable {
    let id = UUID()
    let edit: BlockEdit
}
