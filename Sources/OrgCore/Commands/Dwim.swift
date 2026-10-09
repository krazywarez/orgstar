import Foundation

/// Doom's `+org/dwim-at-point` (RET in normal state): on a heading, TODO becomes the first
/// done keyword of its sequence and a done keyword the first TODO one; on an item, its
/// checkbox toggles; in a src block, the block runs; on a `#+TBLFM` line or in a table with
/// formulas, the table recalculates, otherwise aligns.
public struct OrgDwim: OrgCommand {
    public init() {}
    public var id: String { "org.dwim" }
    public var title: String { "Act at Point" }

    public func applies(in context: EditContext) -> Bool { true }

    public func run(in context: EditContext) -> CommandStep {
        // `+org/dwim-at-point` follows a link first.
        if Links.link(at: context.caret, text: context.text, tree: context.tree) != nil { return OpenLinkAtPoint().run(in: context) }
        if TableRecalculate.tblfmLine(in: context) != nil { return TableRecalculate(all: true).run(in: context) }
        if KeyContext.holds("src", in: context) { return ExecuteSrcBlock().run(in: context) }
        if KeyContext.holds("table", in: context) {
            let buffer = EmacsBuffer(context.text, point: context.caret, settings: context.tree.settings)
            if buffer.firstTblfm(after: buffer.tableEnd()) != nil { return TableRecalculate(all: true).run(in: context) }
            return TableCommand(.align).run(in: context)
        }
        if KeyContext.holds("item", in: context) {
            let toggle = ToggleCheckbox()
            if toggle.applies(in: context) { return toggle.run(in: context) }
        }
        guard headingOnLine(at: context.caret, in: context.tree) != nil else { return .failed("Nothing to do here") }
        let settings = context.tree.settings
        return commitBuffer(context) { buffer in
            guard let current = buffer.todoKeyword,
                  let sequence = settings.todoSequences.first(where: { ($0.active + $0.done).contains { $0.name == current } }) else { return }
            if settings.isDone(current) {
                buffer.setTodoKeyword(sequence.active.first?.name)
            } else if let done = sequence.done.first?.name {
                try buffer.checkTodoBlocking(from: current, to: done)
                buffer.setTodoKeyword(done)
            }
            try buffer.afterTodoChange(previous: current, answers: context.answers)
        }
    }
}
