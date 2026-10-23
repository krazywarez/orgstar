import OrgDocument
import SwiftUI

/// Lines removed and added between two versions, with a few lines of context around each change.
public struct DiffView: View {
    let lines: [DiffLine]
    var context = 3

    public init(old: String, new: String) {
        lines = lineDiff(old: old, new: new)
    }

    /// Lines to show, nil standing for a run of unchanged lines left out.
    private var shown: [DiffLine?] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for i in changed { keep.formUnion(max(0, i - context)...min(lines.count - 1, i + context)) }
        var out: [DiffLine?] = []
        var skipped = false
        for i in lines.indices {
            if keep.contains(i) {
                out.append(lines[i])
                skipped = false
            } else if !skipped {
                out.append(nil)
                skipped = true
            }
        }
        return out
    }

    public var body: some View {
        let shown = shown
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty { Text("No differences").foregroundStyle(.secondary).padding(8) }
                ForEach(shown.indices, id: \.self) { i in
                    if let line = shown[i] {
                        Text(prefix(line.kind) + line.text.trimmingCharacters(in: .newlines))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line.kind))
                    } else {
                        Text("⋯").foregroundStyle(.secondary)
                    }
                }
            }
            #if os(macOS)
            .font(.system(.callout, design: .monospaced))
            #else
            .font(.system(.footnote, design: .monospaced))
            #endif
            .textSelection(.enabled)
            .padding(8)
        }
        .defaultScrollAnchor(.topLeading)
        #if os(macOS)
        .background(Color(nsColor: .textBackgroundColor))
        #else
        .background(Color(uiColor: .secondarySystemBackground))
        #endif
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .same: "  "
        case .removed: "- "
        case .added: "+ "
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .same: .clear
        case .removed: .red.opacity(0.18)
        case .added: .green.opacity(0.18)
        }
    }
}
