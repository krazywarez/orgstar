import SwiftUI

extension EmacsImport {
    /// The items by kind of change, empty kinds left out; agenda folders only when `folders`.
    public func groups(folders: Bool) -> [(String, [Item])] {
        [
            ("Settings", items.filter { if case .setting = $0.change { true } else { false } }),
            ("Folders", folders ? items.filter { if case .folder = $0.change { true } else { false } } : []),
            ("Capture templates", items.filter { if case .capture = $0.change { true } else { false } }),
            ("Key bindings", items.filter { if case .binding = $0.change { true } else { false } }),
            ("Structure templates", items.filter { if case .structureTemplate = $0.change { true } else { false } }),
            ("Agenda views", items.filter { if case .view = $0.change { true } else { false } }),
        ].filter { !$0.1.isEmpty }
    }
}

/// A section of toggles per group of an import, then what wasn't imported and why.
public struct EmacsImportSections: View {
    let result: EmacsImport
    let groups: [(String, [EmacsImport.Item])]
    @Binding var selected: Set<Int>
    let font: Font

    public init(result: EmacsImport, groups: [(String, [EmacsImport.Item])], selected: Binding<Set<Int>>, font: Font) {
        self.result = result
        self.groups = groups
        _selected = selected
        self.font = font
    }

    public var body: some View {
        ForEach(groups, id: \.0) { title, items in
            Section(title) {
                ForEach(items) { item in
                    Toggle(isOn: Binding { selected.contains(item.id) } set: { on in
                        if on { selected.insert(item.id) } else { selected.remove(item.id) }
                    }) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.summary).font(font)
                            Text([item.name == item.summary ? nil : item.name, item.source.isEmpty ? nil : item.source].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        let notes = result.unsupported.map { ($0.id, $0.name, $0.reason, $0.source) } + result.unreadable.map { ($0.id, $0.name, $0.reason, $0.source) }
        if !notes.isEmpty || !result.problems.isEmpty {
            Section("Not imported") {
                ForEach(result.problems, id: \.self) { Text($0).foregroundStyle(.red) }
                ForEach(notes, id: \.0) { note in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.1).font(font)
                        Text("\(note.2) · \(note.3)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
