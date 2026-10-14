import Foundation
import OrgCore

public protocol FileSystem: Sendable {
    /// The file's bytes, or nil if it doesn't exist.
    func read(_ url: URL) throws -> [UInt8]?
    /// Replaces the file through a temporary file in the same folder. Returns the bytes that
    /// were replaced, read from the replaced file itself, or nil if there was none.
    func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]?
}

public protocol RecoveryStore: Sendable {
    func keep(_ bytes: [UInt8], for url: URL, label: String) throws
    /// Offered the version a save is about to replace, to keep now and then as a snapshot.
    func keepSnapshot(_ bytes: [UInt8], for url: URL) throws
}

extension RecoveryStore {
    public func keepSnapshot(_ bytes: [UInt8], for url: URL) throws {}
}

public enum SaveOutcome: Sendable, Equatable {
    case saved
    /// The file had changed since it was read; the change merged cleanly into the buffer and
    /// the merge was written.
    case mergedAndSaved([TextEdit])
    /// The file had changed and the change conflicts. Nothing was written; the buffer is
    /// unchanged.
    case conflict([MergeConflict])
    /// Another writer replaced the file between our last check and our write. Ours is on disk;
    /// theirs is in recovery and was merged into the buffer where possible.
    case overwroteExternalChange(DocumentState.ExternalChange)
    /// Another writer changed the file right after our write. Theirs is on disk; ours is in
    /// recovery.
    case changedAfterWrite(DocumentState.ExternalChange)
}

public enum SaveError: Error, Equatable {
    case fileKeepsChanging
}

/// The save sequence from the design: read, merge if the file moved, check again, replace,
/// read back. Emacs and Syncthing don't coordinate, so the sequence can't lock them out; it
/// narrows the window and makes sure every version it displaces lands in recovery.
public struct Saver: Sendable {
    public let fileSystem: FileSystem
    public let recovery: RecoveryStore
    public var maxAttempts = 3

    public init(fileSystem: FileSystem, recovery: RecoveryStore) {
        self.fileSystem = fileSystem
        self.recovery = recovery
    }

    public func save(_ state: inout DocumentState, to url: URL) throws -> SaveOutcome {
        guard state.isEditable else { throw DocumentState.EditError.readOnly }
        for _ in 0..<maxAttempts {
            let disk = try fileSystem.read(url)
            var merged: [TextEdit]?
            if let disk, disk != state.mergeBase {
                try recovery.keep(disk, for: url, label: "external")
                try recovery.keep(state.encodedText(), for: url, label: "local")
                switch state.diskChanged(to: disk) {
                case .conflict(let conflicts): return .conflict(conflicts)
                case .merged(let edits), .reloaded(let edits): merged = edits
                case .unchanged: break
                }
            }
            let bytes = try state.encodedText()
            guard try fileSystem.read(url) == disk else { continue }
            // A snapshot is a convenience: one that can't be kept doesn't stop the save.
            if let disk, disk != bytes { try? recovery.keepSnapshot(disk, for: url) }

            let replaced = try fileSystem.replace(url, with: bytes)
            state.didWrite(bytes)
            if replaced != disk, let replaced {
                try recovery.keep(replaced, for: url, label: "external")
                return .overwroteExternalChange(state.mergeOverwritten(replaced, base: disk ?? []))
            }

            if let after = try fileSystem.read(url), after != bytes {
                try recovery.keep(bytes, for: url, label: "local")
                return .changedAfterWrite(state.diskChanged(to: after))
            }
            return merged.map { .mergedAndSaved($0) } ?? .saved
        }
        throw SaveError.fileKeepsChanging
    }

    /// Writes the buffer over whatever is on disk, for keeping our version over a conflicting
    /// one. The replaced version goes to recovery unless it is the merge base.
    public func overwrite(_ state: inout DocumentState, to url: URL) throws {
        let bytes = try state.encodedText()
        if let replaced = try fileSystem.replace(url, with: bytes), replaced != state.mergeBase {
            try recovery.keep(replaced, for: url, label: "external")
        }
        state.didWrite(bytes)
    }
}
