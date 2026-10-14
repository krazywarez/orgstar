#if os(iOS)
import OrgApp
import OrgDocument
import SwiftUI
import UIKit

/// Lines removed and added between two versions, with a few lines of context around each change.
struct DiffView: View {
    let lines: [DiffLine]
    var context = 3

    init(old: String, new: String) {
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

    var body: some View {
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
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
        }
        .defaultScrollAnchor(.topLeading)
        .background(Color(uiColor: .secondarySystemBackground))
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

/// The buffer and the file on disk changed differently: what differs, and how to settle it.
struct ConflictSheet: View {
    let session: DocumentSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text((session.conflict ?? "") + " Lines marked - are on disk, + in your version. The version you don't keep is saved in the recovery folder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let versions = session.conflictVersions() {
                    DiffView(old: versions.disk, new: versions.mine)
                }
                Button("Keep Mine") { session.keepMine(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                HStack {
                    Button("Use Disk Version") { session.useDiskVersion(); dismiss() }
                    Spacer()
                    Button("Merge with Markers") { session.mergeConflictWithMarkers(); dismiss() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Conflicting Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() } } }
        }
    }
}

/// Syncthing's conflict copies of the open file: each against the file, and what to keep.
struct SyncConflictSheet: View {
    let session: DocumentSession
    let report: (String) -> Void
    @State private var copies: [URL] = []
    @State private var selected: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                if copies.isEmpty {
                    Text("No conflict copies of this file.").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Picker("Copy", selection: $selected) {
                        ForEach(copies, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                    }
                    Text("Lines marked - are in the file, + in the copy. The copy goes to the recovery folder when it's resolved.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let selected, let copy = session.recoveryText(selected), let mine = session.document?.text {
                        DiffView(old: mine, new: copy)
                    }
                    if let selected {
                        HStack {
                            Button("Keep File") { resolve(selected, .keepFile) }
                            Spacer()
                            Button("Merge") { resolve(selected, .merge) }
                            Spacer()
                            Button("Use Copy") { resolve(selected, .useCopy) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .navigationTitle("Sync Conflict Copies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        copies = session.syncConflictCopies()
        if selected.map({ !copies.contains($0) }) ?? true { selected = copies.first }
    }

    private func resolve(_ copy: URL, _ resolution: DocumentSession.CopyResolution) {
        if let message = session.resolve(copy: copy, resolution) { report(message) }
        reload()
        if copies.isEmpty { dismiss() }
    }
}

/// Versions of the open file kept in the recovery folder, newest first; one against the buffer.
struct RecoverySheet: View {
    let session: DocumentSession
    let report: (String) -> Void
    @State private var versions: [(url: URL, date: Date, label: String)] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(versions, id: \.url) { version in
                NavigationLink {
                    detail(version.url)
                } label: {
                    VStack(alignment: .leading) {
                        Text(version.date.formatted(date: .abbreviated, time: .standard))
                        Text(Self.describe(version.label)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if versions.isEmpty { ContentUnavailableView("No Kept Versions", systemImage: "clock.arrow.circlepath") }
            }
            .navigationTitle("Recovered Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear { versions = session.recoveryVersions() }
    }

    private func detail(_ version: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lines marked - are in the buffer, + in the kept version.").font(.callout).foregroundStyle(.secondary)
            if let kept = session.recoveryText(version), let mine = session.document?.text {
                DiffView(old: mine, new: kept)
            }
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Restore") {
                    report(session.restore(version) ?? "Restored; undo brings back what was there.")
                    dismiss()
                }
            }
        }
    }

    static func describe(_ label: String) -> String {
        switch label {
        case "local": "Your version, replaced"
        case "external": "Disk version, replaced"
        case "sync-conflict": "Sync conflict copy"
        case "snapshot": "Snapshot, before a save"
        default: label
        }
    }
}
#endif
