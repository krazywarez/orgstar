import OrgCore

/// Which headings are folded: whole subtrees, or only their own bodies.
public struct FoldState: Sendable, Equatable {
    public var folds: Set<Int>
    public var bodyFolds: Set<Int>

    public init(folds: Set<Int> = [], bodyFolds: Set<Int> = []) {
        self.folds = folds
        self.bodyFolds = bodyFolds
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

    /// Shift-TAB: overview, contents, show all, and around.
    public static func cycleGlobal(from current: GlobalVisibility?, in tree: OrgTree) -> (GlobalVisibility, FoldState) {
        let next: GlobalVisibility = switch current {
        case .overview: .contents
        case .contents: .showAll
        case .showAll, nil: .overview
        }
        return (next, foldState(for: next, in: tree))
    }

    public static func foldState(for visibility: GlobalVisibility, in tree: OrgTree) -> FoldState {
        let outline = outline(tree)
        switch visibility {
        case .overview: return FoldState(folds: Set(outline.filter(\.isTopLevel).map(\.start)))
        case .contents: return FoldState(bodyFolds: Set(outline.map(\.start)))
        case .showAll: return FoldState()
        }
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

    /// Words of every `#+STARTUP:` line. Only element-level keywords count, so text inside
    /// blocks and paragraphs is never read as a setting.
    public static func startupOptions(_ tree: OrgTree) -> [String] {
        var options: [String] = []
        func visit(_ node: GreenNode) {
            for case .node(let child) in node.children {
                switch child.kind {
                case .keyword:
                    let text = child.text
                    if text.uppercased().drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#+STARTUP:"),
                       let colon = text.firstIndex(of: ":") {
                        options += text[text.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
                    }
                case .document, .zerothSection, .section, .drawer:
                    visit(child)
                default:
                    break
                }
            }
        }
        visit(tree.green)
        return options
    }
}
