import OrgApp
import SwiftUI

/// A window's panes as its layout divides them, with a draggable divider at each split.
struct PaneLayoutView<Content: View>: View {
    let layout: PaneLayout
    let window: WindowModel
    @ViewBuilder let content: (EditorPane) -> Content

    var body: some View {
        switch layout {
        case .pane(let id):
            if let pane = window.pane(id) { content(pane) } else { Color.clear }
        case .split(let axis, let first, let second, let fraction):
            GeometryReader { geometry in
                let total = axis == .horizontal ? geometry.size.width : geometry.size.height
                let firstSize = max(80, min(max(80, total - 80), total * fraction))
                let divider = SplitDivider(axis: axis, firstSize: firstSize) { size in
                    window.setFraction(size / max(total, 1), ofSplitStartingWith: first.panes[0])
                }
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        PaneLayoutView(layout: first, window: window, content: content).frame(width: firstSize)
                        divider
                        PaneLayoutView(layout: second, window: window, content: content).frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        PaneLayoutView(layout: first, window: window, content: content).frame(height: firstSize)
                        divider
                        PaneLayoutView(layout: second, window: window, content: content).frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

/// The line between two panes; dragging it resizes the first.
struct SplitDivider: View {
    let axis: PaneLayout.Axis
    let firstSize: CGFloat
    let resize: (CGFloat) -> Void
    @State private var start: CGFloat?

    var body: some View {
        let horizontal = axis == .horizontal
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .frame(maxWidth: horizontal ? 1 : .infinity, maxHeight: horizontal ? .infinity : 1)
            .overlay(Color.clear.frame(width: horizontal ? 7 : nil, height: horizontal ? nil : 7).contentShape(Rectangle()).onHover { inside in
                if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let base = start ?? firstSize
                start = base
                resize(base + (horizontal ? drag.translation.width : drag.translation.height))
            }.onEnded { _ in start = nil }))
            .accessibilityHidden(true)
    }
}

/// One pane: its tabs, its editor, or a placeholder while it shows nothing. A thin bar marks
/// the focused pane when there are several.
struct PaneCell: View {
    let pane: EditorPane
    let window: WindowModel
    let session: DocumentSession
    let commands: AppCommands
    let showTabBar: Bool
    let onAppCommand: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showTabBar { BufferTabs(session: session, pane: pane) }
            if pane.path != nil {
                PaneView(pane: pane, session: session, commands: commands, settings: commands.editorSettings, onAppCommand: onAppCommand)
            } else {
                ContentUnavailableView("No buffer", systemImage: "rectangle.dashed", description: Text("Choose a file, or press ⌘P."))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        window.focus(pane.id)
                        commands.editor = nil
                    }
            }
        }
        .overlay(alignment: .top) {
            if window.paneCount > 1, window.focused == pane.id {
                Rectangle().fill(Color.accentColor).frame(height: 2).accessibilityHidden(true)
            }
        }
    }
}
