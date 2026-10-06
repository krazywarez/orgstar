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
    /// `org-log-repeat` `time`: completing a repeating entry records LAST_REPEAT and a state note.
    public var logRepeat: Bool
    /// `org-log-done`: CLOSED when an entry becomes done, and a note with `.note`.
    public var logDone: LogHow?
    /// `org-log-into-drawer`: the drawer state notes go in, or nil for none.
    public var logIntoDrawer: String?
    /// `org-use-fast-todo-selection` `auto`: with keys in the keywords, C-c C-t asks for one.
    public var fastTodoSelection: Bool
    /// `org-cycle-hide-drawer-startup`: drawers are folded when a file opens.
    public var hideDrawerStartup: Bool
    /// `org-cycle-hide-block-startup`: blocks are folded when a file opens.
    public var hideBlockStartup: Bool
    /// `fill-column` for M-q.
    public var fillColumn: Int
    /// `org-hide-emphasis-markers`: table alignment measures emphasis without its markers.
    public var hideEmphasisMarkers: Bool
    /// `org-pretty-entities`: table alignment measures `\alpha` as `α`.
    public var prettyEntities: Bool
    /// `org-use-sub-superscripts` `{}`: only `_{…}` and `^{…}` are sub- and superscripts.
    public var subSuperscriptsNeedBraces: Bool

    public init(
        tagsColumn: Int = -77, insertHeadingRespectContent: Bool = false, metaReturnMaySplitLine: Bool = true,
        listAllowAlphabetical: Bool = false, logRepeat: Bool = true, fillColumn: Int = 70,
        hideEmphasisMarkers: Bool = false, prettyEntities: Bool = false, subSuperscriptsNeedBraces: Bool = false,
        logDone: LogHow? = nil, logIntoDrawer: String? = nil, fastTodoSelection: Bool = true,
        hideDrawerStartup: Bool = true, hideBlockStartup: Bool = false
    ) {
        self.hideDrawerStartup = hideDrawerStartup
        self.hideBlockStartup = hideBlockStartup
        self.fastTodoSelection = fastTodoSelection
        self.logDone = logDone
        self.logIntoDrawer = logIntoDrawer
        self.tagsColumn = tagsColumn
        self.insertHeadingRespectContent = insertHeadingRespectContent
        self.metaReturnMaySplitLine = metaReturnMaySplitLine
        self.listAllowAlphabetical = listAllowAlphabetical
        self.logRepeat = logRepeat
        self.fillColumn = fillColumn
        self.hideEmphasisMarkers = hideEmphasisMarkers
        self.prettyEntities = prettyEntities
        self.subSuperscriptsNeedBraces = subSuperscriptsNeedBraces
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
    /// Tags used across the workspace, for completion; read when a command needs them.
    public let knownTags: @Sendable () -> [String]

    public init(
        revision: Int, text: String, tree: OrgTree, selection: [Range<Int>],
        now: Date = Date(), calendar: Calendar = .current, answers: [String: String] = [:], hidden: [Range<Int>] = [],
        options: EditingOptions = .org, knownTags: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.knownTags = knownTags
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
    /// When set, the answer is one of these, or with `requireMatch` false, these are offered.
    public let choices: [String]
    public let requireMatch: Bool
    /// Choices complete the text after the last of these characters (`:` between tags).
    public let completionSeparator: Character?
    /// Single keys answer instead of text.
    public let fast: FastSelection?

    public init(
        key: String, message: String, initial: String = "", choices: [String] = [], requireMatch: Bool = true,
        completionSeparator: Character? = nil, fast: FastSelection? = nil
    ) {
        self.key = key
        self.message = message
        self.initial = initial
        self.choices = choices
        self.requireMatch = requireMatch
        self.completionSeparator = completionSeparator
        self.fast = fast
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
    /// An inserted link was a stored one; it leaves `org-stored-links`.
    case storedLinkUsed(String)
    /// Text for the clipboard (the kill ring).
    case copy(String)
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
    /// Work the platform does outside the text (Emacs, an interpreter); its result comes back
    /// as an edit.
    case external(ExternalRequest)
}

public enum ExternalRequest: Sendable, Equatable {
    /// Recalculate the table whose text is at `table` in Emacs, running `form` with point at
    /// `point`, and put Emacs's table text in its place. `lisp` when its formulas run Lisp.
    case emacsTable(table: Range<Int>, point: Int, form: String, reason: String, lisp: Bool)
    /// Run a src block; `Babel.finish` turns its output into the result edit.
    case babel(BabelJob)
    /// Follow a link: the app opens URLs and files and searches headings.
    case openLink(OrgLink)
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
        TodoCycle(), TodoShift(right: true), TodoShift(right: false), PriorityUp(), PriorityDown(), PromoteHeading(), DemoteHeading(),
        InsertHeading(), InsertHeadingAfterSubtree(), InsertTodoHeading(),
        MoveSubtreeUp(), MoveSubtreeDown(), PromoteSubtree(), DemoteSubtree(),
        NextHeading(), PreviousHeading(), ForwardSameLevel(), BackwardSameLevel(), UpHeading(),
        SetTags(),
        InsertItem(), InsertCheckboxItem(), IndentItem(), OutdentItem(), IndentItemTree(), OutdentItemTree(),
        MoveItemUp(), MoveItemDown(), ToggleCheckbox(),
        InsertTimestamp(), InsertTimestamp(inactive: true), SetPlanning(deadline: false), SetPlanning(deadline: true),
        RemovePlanning(deadline: false), RemovePlanning(deadline: true), FillParagraph(), CreateTable(),
        TableRecalculate(all: false), TableRecalculate(all: true), ExecuteSrcBlock(), OrgDwim(),
        ShiftTimestamp(up: true), ShiftTimestamp(up: false), ShiftTimestampDay(later: true), ShiftTimestampDay(later: false),
        OpenLinkAtPoint(), CreateID(), ToggleComment(), ToggleHeading(), ToggleItem(), MarkSubtree(),
        CopySubtree(cut: false), CopySubtree(cut: true), CloneSubtree(), SortEntries(),
    ]

    public static var everything: [any OrgCommand] { all + TableCommand.Action.allCases.map(TableCommand.init) }

    public static func command(_ id: String) -> (any OrgCommand)? {
        everything.first { $0.id == id }
    }
}
