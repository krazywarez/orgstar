import AppIntents
import OrgApp

/// A folder the user added, by its path.
struct FolderEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Folder"
    static let defaultQuery = Query()

    var id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\((id as NSString).lastPathComponent)", subtitle: "\(id)")
    }

    struct Query: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [FolderEntity] { identifiers.map(FolderEntity.init) }
        func suggestedEntities() async throws -> [FolderEntity] { WorkspaceModel.savedRootPaths().map(FolderEntity.init) }
    }
}

/// While a Focus with this filter is on, the agenda and widgets leave out its folders and
/// their reminders are muted. The system performs it again with no folders when the Focus ends.
struct AgendaFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Hide Folders"
    static let description = IntentDescription("Leaves folders out of the agenda and widgets, and mutes their reminders, while this Focus is on.")

    @Parameter(title: "Folders", default: [])
    var folders: [FolderEntity]

    var displayRepresentation: DisplayRepresentation {
        let names = folders.map { ($0.id as NSString).lastPathComponent }.joined(separator: ", ")
        return DisplayRepresentation(title: names.isEmpty ? "No folders hidden" : "Hide \(names)")
    }

    var appContext: FocusFilterAppContext {
        FocusFilterAppContext(notificationFilterPredicate: HiddenFolders.notificationPredicate(hiding: Set(folders.map(\.id))))
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        HiddenFolders.shared.focus = Set(folders.map(\.id))
        return .result()
    }
}
