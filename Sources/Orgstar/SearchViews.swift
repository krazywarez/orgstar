import AppKit
import OrgApp
import OrgIndex
import OrgWorkspace
import SwiftUI

struct SearchResults: View {
    let results: [HeadingLocation]
    let open: (HeadingLocation) -> Void

    var body: some View {
        List(results, id: \.self) { location in
            Button {
                open(location)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.title.isEmpty ? "(untitled)" : location.title).lineLimit(1)
                    Text((location.path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if results.isEmpty { ContentUnavailableView.search }
        }
    }
}

struct QuickOpenView: View {
    let workspace: WorkspaceModel
    let open: (FileEntry) -> Void
    @State private var query = ""
    /// The highlighted match, moved by ↑/↓ or C-p/C-n and opened by Return.
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let matches = workspace.quickOpen(query)
        let current = min(selected, matches.count - 1)
        VStack(spacing: 0) {
            TextField("Open file", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .onSubmit { if current >= 0 { open(matches[current]) } }
                .onKeyPress(phases: .down) { press in
                    let control = press.modifiers == .control
                    let step = if press.key == .downArrow || control && press.characters == "n" { 1 }
                        else if press.key == .upArrow || control && press.characters == "p" { -1 } else { 0 }
                    guard step != 0 else { return .ignored }
                    selected = max(0, min(current + step, matches.count - 1))
                    return .handled
                }
                .onChange(of: query) { selected = 0 }
            Divider()
            ScrollViewReader { proxy in
                List(matches.indices, id: \.self) { index in
                    let entry = matches[index]
                    Button {
                        open(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.relativePath).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(index == current ? Color.accentColor.opacity(0.25) : Color.clear)
                    .accessibilityAddTraits(index == current ? .isSelected : [])
                }
                .onChange(of: current) { if current >= 0 { proxy.scrollTo(current) } }
            }
        }
        .frame(width: 520, height: 360)
        .onExitCommand { dismiss() }
    }
}
