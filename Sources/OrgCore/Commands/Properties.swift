import Foundation

/// `org-set-property` / `org-entry-put` for one entry.
public struct SetProperty: OrgCommand {
    public let key: String
    public let value: String
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
    public var id: String { "org.property.set" }
    public var title: String { "Set Property" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        if key.uppercased() == "TODO" { return SetTodo(keyword: value.isEmpty ? nil : value).run(in: context) }
        guard key.range(of: "^[^\\s:]+$", options: .regularExpression) != nil else { return .failed("Invalid property name: \"\(key)\"") }
        return commitBuffer(context) { buffer in
            buffer.saveExcursion { buffer.entryPut(key, value) }
        }
    }
}

/// `org-todo` with a keyword (nil for none), with the statistics and repeat it brings.
public struct SetTodo: OrgCommand {
    public let keyword: String?
    public init(keyword: String?) { self.keyword = keyword }
    public var id: String { "org.todo.set" }
    public var title: String { "Set TODO Keyword" }
    public func applies(in context: EditContext) -> Bool { entryHeading(at: context.caret, in: context.tree) != nil }
    public func run(in context: EditContext) -> CommandStep {
        guard entryHeading(at: context.caret, in: context.tree) != nil else { return .failed("Before first headline") }
        let settings = context.tree.settings
        if let keyword, !settings.todoSequences.contains(where: { ($0.active + $0.done).contains { $0.name == keyword } }) {
            return .failed("\"\(keyword)\" is not a valid TODO state")
        }
        return commitBuffer(context) { buffer in
            try buffer.saveExcursion {
                let previous = buffer.todoKeyword
                try buffer.checkTodoBlocking(from: previous, to: keyword)
                buffer.setTodoKeyword(keyword)
                try buffer.afterTodoChange(previous: previous, answers: context.answers)
            }
        }
    }
}
