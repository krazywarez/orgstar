public struct GreenToken: Sendable, Equatable {
    public let kind: SyntaxKind
    public let text: String
    /// Length in UTF-16 code units.
    public let length: Int

    public init(kind: SyntaxKind, text: String) {
        self.kind = kind
        self.text = text
        self.length = text.utf16.count
    }
}

/// An immutable node. Stores only kind, children and length, so unchanged subtrees can be
/// shared between versions of a document.
public final class GreenNode: Sendable, Equatable {
    public let kind: SyntaxKind
    public let children: [GreenElement]
    /// Length in UTF-16 code units.
    public let length: Int

    public init(kind: SyntaxKind, children: [GreenElement]) {
        self.kind = kind
        self.children = children
        self.length = children.reduce(0) { $0 + $1.length }
    }

    public static func == (lhs: GreenNode, rhs: GreenNode) -> Bool {
        lhs === rhs || (lhs.kind == rhs.kind && lhs.children == rhs.children)
    }

    public var text: String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        for child in children {
            switch child {
            case .node(let node): node.write(to: &out)
            case .token(let token): out += token.text
            }
        }
    }
}

public enum GreenElement: Sendable, Equatable {
    case node(GreenNode)
    case token(GreenToken)

    public var length: Int {
        switch self {
        case .node(let node): node.length
        case .token(let token): token.length
        }
    }
}

struct GreenBuilder {
    private var stack: [(kind: SyntaxKind, children: [GreenElement])] = []
    private var root: GreenNode?

    mutating func start(_ kind: SyntaxKind) {
        stack.append((kind, []))
    }

    mutating func token(_ kind: SyntaxKind, _ text: some StringProtocol) {
        guard !text.isEmpty else { return }
        stack[stack.count - 1].children.append(.token(GreenToken(kind: kind, text: String(text))))
    }

    mutating func finish() {
        let (kind, children) = stack.removeLast()
        let node = GreenNode(kind: kind, children: children)
        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(.node(node))
        }
    }

    func build() -> GreenNode {
        precondition(stack.isEmpty, "unfinished nodes")
        return root!
    }
}
