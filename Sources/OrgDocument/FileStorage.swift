import CryptoKit
import Foundation

/// Reads and replaces files under `NSFileCoordinator`, so iCloud and other coordinating
/// writers see a consistent file.
public struct CoordinatedFileSystem: FileSystem {
    public init() {}

    public func read(_ url: URL) throws -> [UInt8]? {
        try coordinate(reading: url) { url in
            FileManager.default.fileExists(atPath: url.path) ? [UInt8](try Data(contentsOf: url)) : nil
        }
    }

    public func replace(_ url: URL, with bytes: [UInt8]) throws -> [UInt8]? {
        try coordinate(writing: url) { url in
            let manager = FileManager.default
            let folder = url.deletingLastPathComponent()
            let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).orgstar-\(UUID().uuidString)")
            try Data(bytes).write(to: temporary)
            guard manager.fileExists(atPath: url.path) else {
                try manager.moveItem(at: temporary, to: url)
                return nil
            }
            // The backup is the file as it was at the moment of replacement, including any
            // write that landed after our last check.
            let backupName = ".\(url.lastPathComponent).orgstar-backup-\(UUID().uuidString)"
            _ = try manager.replaceItemAt(url, withItemAt: temporary, backupItemName: backupName, options: .withoutDeletingBackupItem)
            let backup = folder.appendingPathComponent(backupName)
            defer { try? manager.removeItem(at: backup) }
            return [UInt8](try Data(contentsOf: backup))
        }
    }

    private func coordinate<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }

    private func coordinate<T>(writing url: URL, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            result = Result { try body(url) }
        }
        if let coordinationError { throw coordinationError }
        return try result!.get()
    }
}

/// Keeps the last `limit` displaced versions per file in `directory/<hash of path>/`.
public struct FileRecoveryStore: RecoveryStore {
    public let directory: URL
    public let limit: Int

    public init(directory: URL, limit: Int = 20) {
        self.directory = directory
        self.limit = limit
    }

    public func folder(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    public func keep(_ bytes: [UInt8], for url: URL, label: String) throws {
        let folder = folder(for: url)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Zero-padded wall-clock nanoseconds sort by time; the UUID keeps same-instant names apart.
        let stamp = String(format: "%020llu", UInt64(Date().timeIntervalSince1970 * 1_000_000_000))
        let name = "\(stamp)-\(label)-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
        try Data(bytes).write(to: folder.appendingPathComponent(name))
        let kept = try manager.contentsOfDirectory(atPath: folder.path).sorted()
        for old in kept.dropLast(limit) {
            try manager.removeItem(at: folder.appendingPathComponent(old))
        }
    }

    /// Kept versions, oldest first.
    public func versions(for url: URL) throws -> [URL] {
        let folder = folder(for: url)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().map { folder.appendingPathComponent($0) }
    }
}
