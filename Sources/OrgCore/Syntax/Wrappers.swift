import Foundation

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

    /// `text` is the document's, read in place rather than copying the node's text.
    static func wrapper(_ node: SyntaxNode, in text: NSString) -> Wrapper? {
        guard let kind = kind(node.kind) else { return nil }
        let start = node.range.lowerBound
        // Blank lines after the element belong to it in the tree, not to the fold.
        var end = node.range.upperBound
        while end > start, [9, 10, 13, 32].contains(text.character(at: end - 1)) { end -= 1 }
        let firstNewline = text.range(of: "\n", options: .literal, range: NSRange(start..<end)).location
        guard firstNewline != NSNotFound else { return nil }
        var closeStart = end
        while closeStart > start, text.character(at: closeStart - 1) != 10 { closeStart -= 1 }
        let hiddenEnd = end < node.range.upperBound ? end + 1 : end
        return Wrapper(kind: kind, start: start, closeLine: closeStart, hidden: (firstNewline + 1)..<hiddenEnd)
    }

    /// Elements a drawer or block can sit in.
    static let containers: Set<SyntaxKind> = [.document, .zerothSection, .section, .drawer, .block, .dynamicBlock, .plainList, .item, .footnoteDefinition]

    /// Every drawer and block, in document order, nested ones included.
    public static func all(_ tree: OrgTree) -> [Wrapper] {
        var result: [Wrapper] = []
        let text = tree.text as NSString
        func walk(_ node: SyntaxNode) {
            for child in node.children {
                if let wrapper = wrapper(child, in: text) { result.append(wrapper) }
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
            if child.range.lowerBound == offset, let wrapper = wrapper(child, in: tree.text as NSString) { return wrapper }
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
            if let wrapper = wrapper(child, in: tree.text as NSString), offset < wrapper.hidden.lowerBound || (wrapper.closeLine..<wrapper.hidden.upperBound).contains(offset) {
                found = wrapper
            }
            node = child
        }
        return found
    }
}
