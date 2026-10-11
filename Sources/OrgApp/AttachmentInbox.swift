import Foundation

/// Files shared from other apps to attach, waiting for the app to ask which entry they go to:
/// a folder for each share in the app group's container, which the share extension writes.
public struct AttachmentInbox: Sendable {
    public let folder: URL

    /// The app group's inbox; nil when the app isn't entitled to the group.
    public init?(group: String = CaptureInbox.group) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        folder = container.appendingPathComponent("Attachments")
    }

    public init(folder: URL) {
        self.folder = folder
    }

    /// `files` copied in as one share.
    public func add(_ files: [URL]) throws {
        let batch = folder.appendingPathComponent(String(format: "%020.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        for file in files {
            try FileManager.default.copyItem(at: file, to: batch.appendingPathComponent(file.lastPathComponent))
        }
    }

    /// The waiting shares, oldest first.
    public func batches() -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.map { folder.appendingPathComponent($0) }
    }

    /// A share's files, by name.
    public static func files(in batch: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: batch.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted().map { batch.appendingPathComponent($0) }
    }

    /// The share and whatever is left of it.
    public func remove(_ batch: URL) {
        try? FileManager.default.removeItem(at: batch)
    }
}
