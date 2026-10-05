import Foundation

/// Org options that change what commands write, as the user's Emacs has them.
public struct EditingOptions: Sendable, Equatable, Codable {
    /// `org-tags-column`: negative aligns tags to end at that column, 0 puts them one space
    /// after the title.
    public var tagsColumn: Int
    /// `org-insert-heading-respect-content`: M-RET adds the heading after the subtree.
    public var insertHeadingRespectContent: Bool
    /// `org-M-RET-may-split-line`: M-RET in the middle of a line splits it.
    public var metaReturnMaySplitLine: Bool
    /// `org-list-allow-alphabetical`: `a.` and `A)` are list bullets.
    public var listAllowAlphabetical: Bool

    public init(tagsColumn: Int = -77, insertHeadingRespectContent: Bool = false, metaReturnMaySplitLine: Bool = true, listAllowAlphabetical: Bool = false) {
        self.tagsColumn = tagsColumn
        self.insertHeadingRespectContent = insertHeadingRespectContent
        self.metaReturnMaySplitLine = metaReturnMaySplitLine
        self.listAllowAlphabetical = listAllowAlphabetical
    }

    /// Org's own defaults.
    public static let org = EditingOptions()
}

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
    public let options: EditingOptions

    public init(
        revision: Int, text: String, tree: OrgTree, selection: [Range<Int>],
        now: Date = Date(), calendar: Calendar = .current, answers: [String: String] = [:], hidden: [Range<Int>] = [],
        options: EditingOptions = .org
    ) {
        self.revision = revision
        self.text = text
        self.tree = tree
        self.selection = selection
        self.now = now
        self.calendar = calendar
        self.answers = answers
        self.hidden = hidden
        self.options = options
    }

    public var caret: Int { selection.first?.lowerBound ?? 0 }
}

public struct Prompt: Sendable, Equatable {
    /// The key the answer comes back under in `EditContext.answers`.
    public let key: String
    public let message: String
    /// Text the answer field starts with.
    public let initial: String
    /// When set, the answer is one of these.
    public let choices: [String]

    public init(key: String, message: String, initial: String = "", choices: [String] = []) {
        self.key = key
        self.message = message
        self.initial = initial
        self.choices = choices
    }
}

/// Edits computed elsewhere (refiling to another file, archiving), applied like any command's
/// result. Fails if the document changed since they were computed.
public struct PrecomputedEdit: OrgCommand {
    public let result: EditResult
    public init(_ result: EditResult) { self.result = result }
    public var id: String { "internal.precomputed" }
    public var title: String { "Apply Edit" }
    public func applies(in context: EditContext) -> Bool { context.revision == result.baseRevision }
    public func run(in context: EditContext) -> CommandStep {
        context.revision == result.baseRevision ? .commit(result) : .failed("The file changed; try again.")
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
        SetTags(),
        InsertItem(), InsertCheckboxItem(), IndentItem(), OutdentItem(), IndentItemTree(), OutdentItemTree(),
        MoveItemUp(), MoveItemDown(), ToggleCheckbox(),
    ]

    public static func command(_ id: String) -> (any OrgCommand)? {
        all.first { $0.id == id }
    }
}
