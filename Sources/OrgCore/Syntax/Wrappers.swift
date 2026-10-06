/// Drawers and blocks, the elements org folds on their own (`org-fold-hide-drawer-toggle`,
/// `org-fold-hide-block-toggle`).
public struct Wrapper: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case drawer, block }

    public let kind: Kind
    /// Start of the opening line (`:PROPERTIES:`, `#+begin_src`).
    public let start: Int
    /// Start of the closing line (`:END:`, `#+end_src`).
    public let closeLine: Int
    /// What folding hides: every line after the opening one, through the closing line.
    public let hidden: Range<Int>
}

public enum Wrappers {
    static func kind(_ kind: SyntaxKind) -> Wrapper.Kind? {
        switch kind {
        case .drawer, .propertyDrawer: .drawer
        case .block, .dynamicBlock: .block
        default: nil
        }
    }

    static func wrapper(_ node: SyntaxNode) -> Wrapper? {
        guard let kind = kind(node.kind) else { return nil }
        let units = Array(node.text.utf16)
        // Blank lines after the element belong to it in the tree, not to the fold.
        var end = units.count
        while end > 0, [9, 10, 13, 32].contains(units[end - 1]) { end -= 1 }
        guard let firstNewline = units.firstIndex(of: 10), firstNewline < end else { return nil }
        var closeStart = end
        while closeStart > 0, units[closeStart - 1] != 10 { closeStart -= 1 }
        let hiddenEnd = end < units.count ? end + 1 : end
        return Wrapper(kind: kind, start: node.range.lowerBound, closeLine: node.range.lowerBound + closeStart,
                       hidden: (node.range.lowerBound + firstNewline + 1)..<(node.range.lowerBound + hiddenEnd))
    }

    /// Elements a drawer or block can sit in.
    static let containers: Set<SyntaxKind> = [.document, .zerothSection, .section, .drawer, .block, .dynamicBlock, .plainList, .item, .footnoteDefinition]

    /// Every drawer and block, in document order, nested ones included.
    public static func all(_ tree: OrgTree) -> [Wrapper] {
        var result: [Wrapper] = []
        func walk(_ node: SyntaxNode) {
            for child in node.children {
                if let wrapper = wrapper(child) { result.append(wrapper) }
                if containers.contains(child.kind) { walk(child) }
            }
        }
        walk(tree.root)
        return result
    }

    /// The drawer or block whose opening line starts at `offset`.
    public static func starting(at offset: Int, in tree: OrgTree) -> Wrapper? {
        var node = tree.root
        while let child = node.child(containing: offset) {
            if child.range.lowerBound == offset, let wrapper = wrapper(child) { return wrapper }
            node = child
        }
        return nil
    }

    /// The innermost drawer or block whose opening or closing line holds `offset`, the lines
    /// TAB toggles it from.
    public static func toggleable(at offset: Int, in tree: OrgTree) -> Wrapper? {
        var node = tree.root
        var found: Wrapper?
        while let child = node.child(containing: offset) {
            if let wrapper = wrapper(child), offset < wrapper.hidden.lowerBound || (wrapper.closeLine..<wrapper.hidden.upperBound).contains(offset) {
                found = wrapper
            }
            node = child
        }
        return found
    }
}
