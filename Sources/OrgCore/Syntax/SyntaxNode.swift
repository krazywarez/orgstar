/// A view of a green node at an absolute offset, with a parent link. Created on demand.
public final class SyntaxNode: Sendable {
    public let green: GreenNode
    public let offset: Int
    public let parent: SyntaxNode?

    init(green: GreenNode, offset: Int, parent: SyntaxNode?) {
        self.green = green
        self.offset = offset
        self.parent = parent
    }

    public var kind: SyntaxKind { green.kind }
    public var range: Range<Int> { offset..<(offset + green.length) }
    public var text: String { green.text }

    public var children: [SyntaxNode] {
        var result: [SyntaxNode] = []
        var at = offset
        for child in green.children {
            if case .node(let node) = child {
                result.append(SyntaxNode(green: node, offset: at, parent: self))
            }
            at += child.length
        }
        return result
    }

    public var tokens: [SyntaxToken] {
        var result: [SyntaxToken] = []
        var at = offset
        for child in green.children {
            if case .token(let token) = child {
                result.append(SyntaxToken(kind: token.kind, text: token.text, range: at..<(at + token.length)))
            }
            at += child.length
        }
        return result
    }

    /// Child nodes overlapping `range`. Only those are created, so a section with thousands of
    /// children costs little when the range is small.
    public func children(overlapping range: Range<Int>) -> [SyntaxNode] {
        var result: [SyntaxNode] = []
        var at = offset
        for child in green.children {
            let childRange = at..<(at + child.length)
            if childRange.lowerBound >= range.upperBound, !range.isEmpty { break }
            if case .node(let node) = child, childRange.overlaps(range) {
                result.append(SyntaxNode(green: node, offset: at, parent: self))
            }
            at = childRange.upperBound
        }
        return result
    }

    /// The child node whose range contains `position`.
    public func child(containing position: Int) -> SyntaxNode? {
        var at = offset
        for child in green.children {
            let end = at + child.length
            if position < end {
                if case .node(let node) = child, position >= at { return SyntaxNode(green: node, offset: at, parent: self) }
                return nil
            }
            at = end
        }
        return nil
    }

    /// The first child node of `kind`.
    public func firstChild(_ kind: SyntaxKind) -> SyntaxNode? {
        var at = offset
        for child in green.children {
            if case .node(let node) = child, node.kind == kind { return SyntaxNode(green: node, offset: at, parent: self) }
            at += child.length
        }
        return nil
    }

    public enum Element {
        case node(SyntaxNode)
        case token(SyntaxToken)
    }

    /// Child nodes and tokens in document order.
    public var elements: [Element] {
        var result: [Element] = []
        var at = offset
        for child in green.children {
            switch child {
            case .node(let node): result.append(.node(SyntaxNode(green: node, offset: at, parent: self)))
            case .token(let token): result.append(.token(SyntaxToken(kind: token.kind, text: token.text, range: at..<(at + child.length))))
            }
            at += child.length
        }
        return result
    }

    /// This node and every node below it, in document order.
    public func descendants() -> [SyntaxNode] {
        [self] + children.flatMap { $0.descendants() }
    }
}

public struct SyntaxToken: Sendable, Equatable {
    public let kind: SyntaxKind
    public let text: String
    public let range: Range<Int>
}

public struct OrgTree: Sendable {
    public let green: GreenNode
    public let settings: OrgSettings

    public var root: SyntaxNode { SyntaxNode(green: green, offset: 0, parent: nil) }
    public var text: String { green.text }
}
