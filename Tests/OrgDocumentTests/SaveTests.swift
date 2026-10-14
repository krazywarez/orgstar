import Foundation
import OrgCore
import Testing
@testable import OrgDocument

/// An in-memory file with hooks that let another writer change it at each step of a save.
final class FaultyFileSystem: FileSystem, @unchecked Sendable {
    var file: [UInt8]?
    var reads = 0
    /// Content another writer puts in place just before the n-th read (1-based).
    var beforeRead: [Int: [UInt8]] = [:]
    /// Content another writer puts in place just before our replace.
    var beforeReplace: [UInt8]?

    init(_ text: String?) {
        file = text.map { Array($0.utf8) }
    }

    func read(_ url: URL) throws -> [UInt8]? {
        reads += 1
        if let injected = beforeRead[reads] { file = injected }
        return file
    }

    func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]? {
        if let injected = beforeReplace { file = injected }
        let replaced = file
        file = bytes
        return replaced
    }

    var text: String? { file.map { String(decoding: $0, as: UTF8.self) } }
}

final class MemoryRecovery: RecoveryStore, @unchecked Sendable {
    var kept: [(label: String, text: String)] = []

    func keep(_ bytes: [UInt8], for url: URL, label: String) throws {
        kept.append((label, String(decoding: bytes, as: UTF8.self)))
    }

    func contains(_ text: String) -> Bool { kept.contains { $0.text == text } }
}

let url = URL(fileURLWithPath: "/notes/a.org")

/// A buffer loaded from "a\nb\nc\n" with its first line changed to "A".
func editedState() throws -> DocumentState {
    var doc = state("a\nb\nc\n")
    try doc.apply([TextEdit(range: 0..<1, replacement: "A")], baseRevision: 0)
    return doc
}

struct SaveTests {
    @Test func plainSave() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        let recovery = MemoryRecovery()
        var doc = try editedState()
        #expect(try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) == .saved)
        #expect(files.text == "A\nb\nc\n")
        #expect(!doc.isDirty)
        #expect(recovery.kept.isEmpty)
    }

    @Test func missingFileIsCreated() throws {
        let files = FaultyFileSystem(nil)
        var doc = try editedState()
        #expect(try Saver(fileSystem: files, recovery: MemoryRecovery()).save(&doc, to: url) == .saved)
        #expect(files.text == "A\nb\nc\n")
    }

    @Test func readOnlyDocumentsAreNotSaved() {
        var doc = DocumentState(bytes: [0x61, 0xFF])
        #expect(throws: DocumentState.EditError.readOnly) {
            try Saver(fileSystem: FaultyFileSystem("x"), recovery: MemoryRecovery()).save(&doc, to: url)
        }
    }

    // MARK: - Another writer at each step

    @Test func changedBeforeSaveMerges() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeRead[1] = Array("a\nb\nC\n".utf8)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        guard case .mergedAndSaved = try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) else {
            Issue.record("expected a merge")
            return
        }
        #expect(files.text == "A\nb\nC\n")
        #expect(recovery.contains("a\nb\nC\n") && recovery.contains("A\nb\nc\n"))
    }

    @Test func conflictingChangeWritesNothing() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeRead[1] = Array("Z\nb\nc\n".utf8)
        var doc = try editedState()
        guard case .conflict = try Saver(fileSystem: files, recovery: MemoryRecovery()).save(&doc, to: url) else {
            Issue.record("expected a conflict")
            return
        }
        #expect(files.text == "Z\nb\nc\n")
        #expect(doc.text == "A\nb\nc\n")
    }

    @Test func overwriteKeepsTheReplacedVersion() throws {
        let files = FaultyFileSystem("Z\nb\nc\n")
        let recovery = MemoryRecovery()
        var doc = try editedState()
        try Saver(fileSystem: files, recovery: recovery).overwrite(&doc, to: url)
        #expect(files.text == "A\nb\nc\n")
        #expect(!doc.isDirty)
        #expect(recovery.contains("Z\nb\nc\n"))
    }

    @Test func changedBetweenReadAndCheckRetries() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeRead[2] = Array("a\nb\nC\n".utf8)
        var doc = try editedState()
        guard case .mergedAndSaved = try Saver(fileSystem: files, recovery: MemoryRecovery()).save(&doc, to: url) else {
            Issue.record("expected a merge on the second attempt")
            return
        }
        #expect(files.text == "A\nb\nC\n")
    }

    @Test func changedJustBeforeReplaceIsRecovered() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeReplace = Array("a\nb\nC\n".utf8)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        guard case .overwroteExternalChange(.merged) = try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) else {
            Issue.record("expected their change merged into the buffer")
            return
        }
        #expect(files.text == "A\nb\nc\n")
        #expect(recovery.contains("a\nb\nC\n"))
        #expect(doc.text == "A\nb\nC\n")
        #expect(doc.isDirty)
    }

    @Test func changedRightAfterWriteKeepsOursInRecovery() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        files.beforeRead[3] = Array("A\nb\nc\nD\n".utf8)
        let recovery = MemoryRecovery()
        var doc = try editedState()
        guard case .changedAfterWrite(.reloaded) = try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) else {
            Issue.record("expected a reload of their version")
            return
        }
        #expect(recovery.contains("A\nb\nc\n"))
        #expect(doc.text == "A\nb\nc\nD\n")
    }

    @Test func keepsChangingGivesUp() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        for n in stride(from: 2, through: 6, by: 2) { files.beforeRead[n] = Array("a\nb\nc\n\(n)\n".utf8) }
        var doc = try editedState()
        #expect(throws: SaveError.fileKeepsChanging) {
            try Saver(fileSystem: files, recovery: MemoryRecovery()).save(&doc, to: url)
        }
    }
}

struct FileStorageTests {
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func readAndReplace() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.org")
        let files = CoordinatedFileSystem()
        #expect(try files.read(file) == nil)
        #expect(try files.replace(file, with: Array("one\n".utf8)) == nil)
        #expect(try files.replace(file, with: Array("two\n".utf8)) == Array("one\n".utf8))
        #expect(try files.read(file) == Array("two\n".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.org"])
    }

    @Test func savesThroughTheRealFileSystem() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.org")
        try Data("a\nb\nc\n".utf8).write(to: file)
        let recovery = FileRecoveryStore(directory: folder.appendingPathComponent("recovery"))
        var doc = try editedState()
        #expect(try Saver(fileSystem: CoordinatedFileSystem(), recovery: recovery).save(&doc, to: file) == .saved)
        #expect(try String(contentsOf: file, encoding: .utf8) == "A\nb\nc\n")
    }

    @Test func recoveryKeepsTheNewestVersions() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileRecoveryStore(directory: folder, limit: 3)
        for n in 0..<5 { try store.keep(Array("v\(n)".utf8), for: url, label: "local") }
        let versions = try store.versions(for: url)
        #expect(versions.count == 3)
        #expect(try versions.map { try String(contentsOf: $0, encoding: .utf8) } == ["v2", "v3", "v4"])
    }
}

final class SnapshotRecovery: RecoveryStore, @unchecked Sendable {
    var snapshots: [String] = []
    func keep(_ bytes: [UInt8], for url: URL, label: String) throws {}
    func keepSnapshot(_ bytes: [UInt8], for url: URL) throws {
        snapshots.append(String(decoding: bytes, as: UTF8.self))
    }
}

struct SnapshotTests {
    /// A save that changes the file offers the version it replaces as a snapshot.
    @Test func savesOfferTheReplacedVersion() throws {
        let files = FaultyFileSystem("a\nb\nc\n")
        let recovery = SnapshotRecovery()
        var doc = try editedState()
        #expect(try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url) == .saved)
        #expect(recovery.snapshots == ["a\nb\nc\n"])
        // Saving the same text again changes nothing, so nothing is offered.
        _ = try Saver(fileSystem: files, recovery: recovery).save(&doc, to: url)
        #expect(recovery.snapshots.count == 1)
    }

    @Test func keptHourlyWithTheirOwnLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var store = FileRecoveryStore(directory: folder)
        store.now = { clock }
        func labels() throws -> [String] { try store.versions(for: url).map { $0.lastPathComponent.split(separator: "-")[1].description } }
        try store.keepSnapshot(Array("one".utf8), for: url)
        clock += 1800
        try store.keepSnapshot(Array("two".utf8), for: url)
        #expect(try labels() == ["snapshot"])
        clock += 1801
        try store.keepSnapshot(Array("three".utf8), for: url)
        #expect(try labels() == ["snapshot", "snapshot"])
        // Displaced versions don't count towards the hour, and snapshots don't push them out.
        try store.keep(Array("theirs".utf8), for: url, label: "external")
        for _ in 0..<15 {
            clock += 3601
            try store.keepSnapshot(Array("later".utf8), for: url)
        }
        let kept = try labels()
        #expect(kept.filter { $0 == "snapshot" }.count == FileRecoveryStore.snapshotLimit)
        #expect(kept.contains("external"))
    }
}
