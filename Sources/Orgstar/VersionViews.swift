import AppKit
import OrgApp
import OrgDocument
import SwiftUI

/// The buffer and the file on disk changed differently: what differs, and how to settle it.
struct ConflictSheet: View {
    let session: DocumentSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Conflicting changes").font(.headline)
            Text((session.conflict ?? "") + " Lines marked - are on disk, + in your version. The version you don't keep is saved in the recovery folder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let versions = session.conflictVersions() {
                DiffView(old: versions.disk, new: versions.mine)
            }
            HStack {
                Button("Decide Later") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Disk Version") { session.useDiskVersion(); dismiss() }
                Button("Merge with Markers") { session.mergeConflictWithMarkers(); dismiss() }
                    .help("Both sets of changes in the buffer, conflicting lines between <<<<<<< and >>>>>>>")
                Button("Keep Mine") { session.keepMine(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 440)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Sync conflict copies").font(.headline)
            if copies.isEmpty {
                Text("No conflict copies of this file.").foregroundStyle(.secondary)
            } else {
                Picker("Copy", selection: $selected) {
                    ForEach(copies, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
                }
                Text("Lines marked - are in the file, + in the copy. The copy goes to the recovery folder when it's resolved.")
                    .foregroundStyle(.secondary)
                if let selected, let copy = session.recoveryText(selected), let mine = session.document?.text {
                    DiffView(old: mine, new: copy)
                }
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let selected {
                    Button("Keep File") { resolve(selected, .keepFile) }
                    Button("Merge with Markers") { resolve(selected, .merge) }
                    Button("Use Copy") { resolve(selected, .useCopy) }
                }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 440)
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

/// Versions of the open file kept in the recovery folder, newest first, against the buffer.
struct RecoverySheet: View {
    let session: DocumentSession
    let report: (String) -> Void
    @State private var versions: [(url: URL, date: Date, label: String)] = []
    @State private var selected: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HSplitView {
            List(versions, id: \.url, selection: $selected) { version in
                VStack(alignment: .leading) {
                    Text(version.date.formatted(date: .abbreviated, time: .standard))
                    Text(Self.describe(version.label)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(version.url)
            }
            .frame(minWidth: 200, idealWidth: 220)
            VStack(alignment: .leading, spacing: 10) {
                Text("Lines marked - are in the buffer, + in the kept version.").foregroundStyle(.secondary)
                if let selected, let kept = session.recoveryText(selected), let mine = session.document?.text {
                    DiffView(old: mine, new: kept)
                } else {
                    Spacer()
                }
                HStack {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    if let selected {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([selected]) }
                    }
                    Spacer()
                    if let selected {
                        Button("Restore") {
                            if let message = session.restore(selected) { report(message) } else { report("Restored; undo brings back what was there.") }
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            versions = session.recoveryVersions()
            selected = versions.first?.url
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
