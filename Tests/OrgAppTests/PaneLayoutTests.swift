import Testing
@testable import OrgApp

struct PaneLayoutTests {
    @Test func splitsNestAndReadInOrder() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        var layout = PaneLayout.pane(a)
        layout = layout.splitting(a, axis: .horizontal, new: b)
        layout = layout.splitting(b, axis: .vertical, new: c)
        #expect(layout.panes == [a, b, c])
        #expect(layout == .split(axis: .horizontal, first: .pane(a), second: .split(axis: .vertical, first: .pane(b), second: .pane(c), fraction: 0.5), fraction: 0.5))
    }

    @Test func removingAPaneCollapsesItsSplit() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let layout = PaneLayout.pane(a).splitting(a, axis: .horizontal, new: b).splitting(b, axis: .vertical, new: c)
        #expect(layout.removing(b) == .split(axis: .horizontal, first: .pane(a), second: .pane(c), fraction: 0.5))
        #expect(layout.removing(a)?.panes == [b, c])
        #expect(PaneLayout.pane(a).removing(a) == nil)
    }

    @Test func onlyAndNext() {
        let a = PaneID(), b = PaneID(), c = PaneID()
        let layout = PaneLayout.pane(a).splitting(a, axis: .horizontal, new: b).splitting(b, axis: .vertical, new: c)
        #expect(layout.only(b) == .pane(b))
        #expect(layout.next(after: a) == b)
        #expect(layout.next(after: c) == a)
        #expect(layout.next(after: PaneID()) == a)
    }
}
