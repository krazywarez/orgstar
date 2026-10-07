import Foundation

/// Captures shared from other apps, waiting for the app to file them: `org-protocol` capture
/// links in the app group's container, which the share extension writes. The app keeps its
/// template list there for the extension to offer.
public struct CaptureInbox: Sendable {
    public static let group = "group.sh.krz.orgstar"

    public struct Template: Codable, Sendable, Hashable {
        public let key: String
        public let name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    public let folder: URL

    /// The app group's inbox; nil when the app isn't entitled to the group.
    public init?(group: String = CaptureInbox.group) {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        folder = container.appendingPathComponent("Captures")
    }

    public init(folder: URL) {
        self.folder = folder
    }

    private var templatesFile: URL { folder.appendingPathComponent("templates.json") }

    public func add(_ link: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%020.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".link"
        try Data(link.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// The waiting links, oldest first, each removed as it's taken.
    public func take() -> [String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".link") }.sorted()
        return names.compactMap { name in
            let file = folder.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: file) }
            return (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    public func setTemplates(_ templates: [Template]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(templates).write(to: templatesFile, options: .atomic)
    }

    public func templates() -> [Template] {
        (try? JSONDecoder().decode([Template].self, from: Data(contentsOf: templatesFile))) ?? []
    }
}
