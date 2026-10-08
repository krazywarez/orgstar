import OrgCore

/// Which headings are folded, whole subtrees or only their own bodies, and which drawers and
/// blocks. Drawer and block folds are kept apart, as org's `drawer` and `block` fold specs:
/// cycling headings leaves them as they are.
public struct FoldState: Sendable, Equatable {
    public var folds: Set<Int>
    public var bodyFolds: Set<Int>
    /// Opening-line starts of folded drawers and blocks.
    public var wrapperFolds: Set<Int>

    public init(folds: Set<Int> = [], bodyFolds: Set<Int> = [], wrapperFolds: Set<Int> = []) {
        self.folds = folds
        self.bodyFolds = bodyFolds
        self.wrapperFolds = wrapperFolds
    }
}

/// org's global visibility states, cycled by Shift-TAB.
public enum GlobalVisibility: Sendable, Equatable {
    /// Top-level headings only.
    case overview
    /// Every heading, no bodies.
    case contents
    case showAll
}

public struct OutlineEntry: Sendable, Equatable {
    /// Start offset of the heading line.
    public let start: Int
    public let level: Int
    /// The title as written.
    public let title: String
    /// End of the heading's section.
    public let end: Int
    /// Index of the parent entry.
    public let parent: Int?
    public let isTopLevel: Bool
}

extension Presentation {
    /// Every heading in document order.
    public static func outline(_ tree: OrgTree) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        collectOutline(tree.root, parent: nil, topLevel: true, &entries)
        return entries
    }

    private static func collectOutline(_ node: SyntaxNode, parent: Int?, topLevel: Bool, _ entries: inout [OutlineEntry]) {
        for section in node.children where section.kind == .section {
            guard let heading = section.firstChild(.heading) else { continue }
            let index = entries.count
            entries.append(OutlineEntry(
                start: heading.range.lowerBound,
                level: heading.tokens.first { $0.kind == .stars }?.text.count ?? 1,
                title: heading.firstChild(.title)?.text ?? "",
                end: section.range.upperBound,
                parent: parent,
                isTopLevel: topLevel
            ))
            collectOutline(section, parent: index, topLevel: false, &entries)
        }
    }

    /// TAB on a heading: folded, then its children, then the whole subtree, then folded again.
    /// A heading without children goes straight from folded to unfolded.
    public static func cycle(_ heading: Int, in tree: OrgTree, _ state: FoldState) -> FoldState {
        let outline = outline(tree)
        guard let index = outline.firstIndex(where: { $0.start == heading }) else { return state }
        let entry = outline[index]
        let descendants = outline.filter { $0.start > entry.start && $0.start < entry.end }.map(\.start)
        let children = outline.enumerated().filter { $0.element.parent == index }.map(\.element.start)
        var next = state
        func unfoldSubtree() {
            next.folds.subtract([heading] + descendants)
            next.bodyFolds.subtract([heading] + descendants)
        }
        if state.folds.contains(heading) {
            unfoldSubtree()
            next.folds.formUnion(children)
        } else if state.bodyFolds.contains(heading) || descendants.contains(where: { state.folds.contains($0) || state.bodyFolds.contains($0) }) {
            unfoldSubtree()
        } else {
            unfoldSubtree()
            next.folds.insert(heading)
        }
        return next
    }

    /// Doom's `za` (`+org/toggle-fold`) on a heading: folded, it opens one level (its body and
    /// child headings, folded); otherwise it folds.
    public static func toggleFold(_ heading: Int, in tree: OrgTree, _ state: FoldState) -> FoldState {
        isFolded(heading, state) ? showChildren(heading, in: tree, state) : hideSubtree(heading, state)
    }

    /// Doom's `zo` (`+org/open-fold`): a folded heading opens one level; an open one stays.
    public static func openFold(_ heading: Int, in tree: OrgTree, _ state: FoldState) -> FoldState {
        isFolded(heading, state) ? showChildren(heading, in: tree, state) : state
    }

    /// `zc` (`outline-hide-subtree`): the heading's subtree folded.
    public static func hideSubtree(_ heading: Int, _ state: FoldState) -> FoldState {
        var next = state
        next.folds.insert(heading)
        return next
    }

    /// Whether the heading's body is hidden.
    private static func isFolded(_ heading: Int, _ state: FoldState) -> Bool {
        state.folds.contains(heading) || state.bodyFolds.contains(heading)
    }

    /// org's children view of a heading: its body and child headings show, their subtrees folded.
    private static func showChildren(_ heading: Int, in tree: OrgTree, _ state: FoldState) -> FoldState {
        let outline = outline(tree)
        guard let index = outline.firstIndex(where: { $0.start == heading }) else { return state }
        let entry = outline[index]
        let subtree = outline.filter { $0.start >= entry.start && $0.start < entry.end }.map(\.start)
        var next = state
        next.folds.subtract(subtree)
        next.bodyFolds.subtract(subtree)
        next.folds.formUnion(outline.enumerated().filter { $0.element.parent == index }.map(\.element.start))
        return next
    }

    /// TAB at `offset` (`org-cycle`): on the first or last line of a drawer or block, folds or
    /// unfolds it; on a heading, cycles it. Nil elsewhere.
    public static func cycle(at offset: Int, in tree: OrgTree, _ state: FoldState) -> FoldState? {
        if let wrapper = Wrappers.toggleable(at: offset, in: tree) {
            var next = state
            if next.wrapperFolds.remove(wrapper.start) == nil { next.wrapperFolds.insert(wrapper.start) }
            return next
        }
        return heading(containing: offset, in: tree).map { cycle($0, in: tree, state) }
    }

    /// Shift-TAB: overview, contents, show all, and around. Drawer and block folds carry over
    /// from `wrapperFolds`: show all opens blocks, and overview and contents fold the drawers
    /// before the first heading (`org-cycle-hide-drawers`).
    public static func cycleGlobal(from current: GlobalVisibility?, in tree: OrgTree, wrapperFolds: Set<Int> = []) -> (GlobalVisibility, FoldState) {
        let next: GlobalVisibility = switch current {
        case .overview: .contents
        case .contents: .showAll
        case .showAll, nil: .overview
        }
        var state = foldState(for: next, in: tree)
        let wrappers = Wrappers.all(tree)
        switch next {
        case .showAll:
            let blocks = Set(wrappers.filter { $0.kind == .block }.map(\.start))
            state.wrapperFolds = wrapperFolds.subtracting(blocks)
        case .overview, .contents:
            let firstHeading = outline(tree).first?.start ?? Int.max
            state.wrapperFolds = wrapperFolds.union(wrappers.filter { $0.kind == .drawer && $0.start < firstHeading }.map(\.start))
        }
        return (next, state)
    }

    /// The drawers and blocks folded when a file opens: drawers unless `org-cycle-hide-drawer-startup`
    /// is off, blocks when `org-cycle-hide-block-startup` is on; `#+STARTUP` (`hidedrawers`,
    /// `nohidedrawers`, `hideblocks`, `nohideblocks`, `showeverything`) overrides both.
    public static func startupWrapperFolds(_ tree: OrgTree, hideDrawers: Bool = true, hideBlocks: Bool = false) -> Set<Int> {
        Set(startupWrappers(tree, hideDrawers: hideDrawers, hideBlocks: hideBlocks).map(\.start))
    }

    public static func startupWrappers(_ tree: OrgTree, hideDrawers: Bool = true, hideBlocks: Bool = false) -> [Wrapper] {
        var drawers = hideDrawers
        var blocks = hideBlocks
        for option in startupOptions(tree) {
            switch option.lowercased() {
            case "hidedrawers": drawers = true
            case "nohidedrawers": drawers = false
            case "hideblocks": blocks = true
            case "nohideblocks": blocks = false
            case "showeverything": return []
            default: break
            }
        }
        guard drawers || blocks else { return [] }
        return Wrappers.all(tree).filter { $0.kind == .drawer ? drawers : blocks }
    }

    public static func foldState(for visibility: GlobalVisibility, in tree: OrgTree) -> FoldState {
        let outline = outline(tree)
        switch visibility {
        case .overview: return FoldState(folds: Set(outline.filter(\.isTopLevel).map(\.start)))
        case .contents: return FoldState(bodyFolds: Set(outline.map(\.start)))
        case .showAll: return FoldState()
        }
    }

    /// `org-cycle-set-visibility-according-to-property` and `org-cycle-hide-archived-subtrees`
    /// after the startup visibility: each heading's `VISIBILITY` (`folded`, `children`, `content`,
    /// `all`) in turn, then ARCHIVE-tagged subtrees folded.
    public static func applyVisibilityProperties(_ state: FoldState, in tree: OrgTree) -> FoldState {
        let outline = outline(tree)
        let model = DocumentModel(tree: tree)
        var next = state
        for (index, heading) in model.headings.enumerated() {
            guard index < outline.count,
                  let value = heading.properties.last(where: { $0.key.uppercased() == "VISIBILITY" })?.value.lowercased() else { continue }
            let entry = outline[index]
            let descendants = outline.filter { $0.start > entry.start && $0.start < entry.end }.map(\.start)
            let children = outline.enumerated().filter { $0.element.parent == index }.map(\.element.start)
            switch value {
            case "folded":
                next.folds.insert(entry.start)
            case "children":
                next.folds.remove(entry.start)
                next.bodyFolds.remove(entry.start)
                next.folds.formUnion(children)
            case "content":
                next.folds.subtract([entry.start] + descendants)
                next.bodyFolds.formUnion([entry.start] + descendants)
            case "all", "showall":
                next.folds.subtract([entry.start] + descendants)
                next.bodyFolds.subtract([entry.start] + descendants)
            default:
                break
            }
        }
        for (index, heading) in model.headings.enumerated() where index < outline.count && heading.localTags.contains("ARCHIVE") {
            next.folds.insert(outline[index].start)
        }
        return next
    }

    /// Headings of levels 1 through `levels` visible, no bodies.
    public static func foldState(showingLevels levels: Int, in tree: OrgTree) -> FoldState {
        let outline = outline(tree)
        return FoldState(
            folds: Set(outline.filter { $0.level == levels }.map(\.start)),
            bodyFolds: Set(outline.filter { $0.level < levels }.map(\.start))
        )
    }

    /// The fold state for the file's `#+STARTUP` visibility, or nil when it sets none.
    /// `overview`/`fold`, `content`, `showall`/`nofold`/`showeverything`, `show2levels`...
    public static func startupFoldState(_ tree: OrgTree) -> FoldState? {
        var result: FoldState?
        for option in startupOptions(tree) {
            switch option.lowercased() {
            case "overview", "fold": result = foldState(for: .overview, in: tree)
            case "content": result = foldState(for: .contents, in: tree)
            case "showall", "nofold", "showeverything": result = FoldState()
            case let word where word.hasPrefix("show") && word.hasSuffix("levels"):
                if let levels = Int(word.dropFirst(4).dropLast(6)), levels > 0 {
                    result = foldState(showingLevels: levels, in: tree)
                }
            default: break
            }
        }
        return result
    }

    /// Words of every `#+STARTUP:` keyword line (`OrgSettings.startup`); lines inside blocks
    /// are not settings.
    public static func startupOptions(_ tree: OrgTree) -> [String] {
        tree.settings.startup
    }
}
