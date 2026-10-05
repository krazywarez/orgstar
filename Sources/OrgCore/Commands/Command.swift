import Foundation

/// Everything a command may read. Commands never read the clock or the file system, so the
/// same context always gives the same result.
public struct EditContext: Sendable {
    /// The revision `text` and `tree` belong to; results are applied only at this revision.
    public let revision: Int
    public let text: String
    public let tree: OrgTree
    /// Selections in UTF-16 offsets. The first is the main caret.
    public let selection: [Range<Int>]
    public let now: Date
    /// Includes the time zone.
    public let calendar: Calendar
    /// Replies to earlier prompts, by prompt key.
    public let answers: [String: String]
    /// Ranges the view hides (folded text); motion commands skip headings inside them.
    public let hidden: [Range<Int>]

    public init(
        revision: Int, text: String, tree: OrgTree, selection: [Range<Int>],
        now: Date = Date(), calendar: Calendar = .current, answers: [String: String] = [:], hidden: [Range<Int>] = []
    ) {
        self.revision = revision
        self.text = text
        self.tree = tree
        self.selection = selection
        self.now = now
        self.calendar = calendar
        self.answers = answers
        self.hidden = hidden
    }

    public var caret: Int { selection.first?.lowerBound ?? 0 }
}

public struct Prompt: Sendable, Equatable {
    /// The key the answer comes back under in `EditContext.answers`.
    public let key: String
    public let message: String

    public init(key: String, message: String) {
        self.key = key
        self.message = message
    }
}

/// Things a command asks for besides text changes; the platform layer carries them out.
public enum Effect: Sendable, Equatable {
    case message(String)
}

public struct EditResult: Sendable, Equatable {
    public let baseRevision: Int
    /// Non-overlapping, in `baseRevision` coordinates.
    public let edits: [TextEdit]
    /// Selection after the edits, in new coordinates; nil maps the old selection through.
    public let selection: [Range<Int>]?
    public let effects: [Effect]

    public init(baseRevision: Int, edits: [TextEdit], selection: [Range<Int>]? = nil, effects: [Effect] = []) {
        self.baseRevision = baseRevision
        self.edits = edits
        self.selection = selection
        self.effects = effects
    }
}

public enum CommandStep: Sendable, Equatable {
    case commit(EditResult)
    /// Ask, then run again with the answer in `EditContext.answers`.
    case prompt(Prompt)
    /// The command can't run here; nothing changes. The message is for the user, as org's
    /// `user-error`.
    case failed(String)
}

/// A named operation. Keys, menus, the palette and touch controls all run commands.
public protocol OrgCommand: Sendable {
    /// Stable identifier, used by keymaps: `org.todo.cycle`.
    var id: String { get }
    /// Shown in the command palette.
    var title: String { get }
    /// Whether the command means something at the caret; context dispatch (one key, several
    /// commands) runs the first that applies.
    func applies(in context: EditContext) -> Bool
    func run(in context: EditContext) -> CommandStep
}

public enum Commands {
    public static let all: [any OrgCommand] = [
        TodoCycle(), PriorityUp(), PriorityDown(), PromoteHeading(), DemoteHeading(),
        InsertHeading(), InsertHeadingAfterSubtree(), InsertTodoHeading(),
        MoveSubtreeUp(), MoveSubtreeDown(), PromoteSubtree(), DemoteSubtree(),
        NextHeading(), PreviousHeading(), ForwardSameLevel(), BackwardSameLevel(), UpHeading(),
    ]

    public static func command(_ id: String) -> (any OrgCommand)? {
        all.first { $0.id == id }
    }
}
