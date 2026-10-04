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
