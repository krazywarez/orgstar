import CryptoKit
import Foundation

/// Code the user agreed to run (Babel blocks, Lisp table formulas), keyed by file and content
/// hash: a change to the code asks again, as `org-confirm-babel-evaluate` would.
@MainActor
public final class TrustStore {
    private let file: URL
    private var hashes: Set<String>

    public init(file: URL = WorkspaceModel.defaultDirectory.appendingPathComponent("trusted.json")) {
        self.file = file
        hashes = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))) ?? []
    }

    static func key(path: String, content: String) -> String {
        SHA256.hash(data: Data((path + "\u{0}" + content).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func isTrusted(path: String, content: String) -> Bool {
        hashes.contains(Self.key(path: path, content: content))
    }

    public func trust(path: String, content: String) {
        hashes.insert(Self.key(path: path, content: content))
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(hashes).write(to: file, options: .atomic)
    }
}
