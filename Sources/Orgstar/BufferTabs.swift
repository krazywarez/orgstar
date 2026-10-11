import AppKit
import OrgApp
import SwiftUI

/// A divider that resizes the pane before it by dragging. An `HSplitView` inside the window's
/// split view loops on its size constraints in short windows, so this sets a width instead.
struct PaneDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(Color.clear.frame(width: 7).contentShape(Rectangle()).onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                let base = start ?? width
                start = base
                width = min(max(base + drag.translation.width, range.lowerBound), range.upperBound)
            }.onEnded { _ in start = nil }))
            .accessibilityHidden(true)
    }
}

/// A tab for each buffer the pane has shown: click to show it, × to close it, a dot for
/// unsaved edits.
struct BufferTabs: View {
    let session: DocumentSession
    let pane: EditorPane
    @Environment(\.orgTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(pane.shown, id: \.self) { path in
                    tab(path)
                }
            }
        }
        .frame(height: 28)
        .background { Rectangle().fill(theme.color("modeline-background").map(AnyShapeStyle.init) ?? AnyShapeStyle(.bar)) }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tab(_ path: String) -> some View {
        let current = path == pane.path
        return HStack(spacing: 6) {
            Text(session.bufferName(path))
                .lineLimit(1)
                .foregroundStyle(current ? .primary : .secondary)
                .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { session.open(path, in: pane) }
            Button {
                if UnsavedChanges.resolve(session, paths: [path]) { session.kill(path) }
            } label: {
                Image(systemName: session.dirtyPaths.contains(path) ? "circle.fill" : "xmark")
                    .font(.system(size: session.dirtyPaths.contains(path) ? 6 : 9, weight: .semibold))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close \(session.bufferName(path))" + (session.dirtyPaths.contains(path) ? ", unsaved" : ""))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        // A shape, not a color: a color background runs up under the toolbar.
        .background { Rectangle().fill(current ? theme.color("background") ?? Color(nsColor: .textBackgroundColor) : .clear) }
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { session.open(path, in: pane) }
        .help(path)
    }
}
