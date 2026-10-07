import Foundation
import OrgCore

/// Writes what `Tangle.run` produced, as `org-babel-tangle` does: a file whose contents
/// haven't changed is left alone, `:mkdirp` makes its folder, a read-only file is replaced,
/// and the mode is set after writing.
public enum TangleWriter {
    public struct Failure: Error, Equatable {
        public let message: String
    }

    /// The paths written or already up to date, in order.
    @discardableResult
    public static func write(_ output: Tangle.Output, source: String) throws(Failure) -> [String] {
        let manager = FileManager.default
        var paths: [String] = []
        for file in output.files {
            let url = URL(fileURLWithPath: file.path)
            let data = Data(file.contents.utf8)
            if let existing = manager.contents(atPath: file.path), existing == data {
                paths.append(file.path)
                continue
            }
            if (file.path as NSString).standardizingPath == (source as NSString).standardizingPath {
                throw Failure(message: "Not allowed to tangle into the same file as self")
            }
            let folder = url.deletingLastPathComponent()
            if file.makeDirectories {
                do {
                    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                } catch {
                    throw Failure(message: "Can't make \(folder.path): \(error.localizedDescription)")
                }
            }
            if manager.fileExists(atPath: file.path), !manager.isWritableFile(atPath: file.path) {
                try? manager.removeItem(at: url)
            }
            do {
                try data.write(to: url)
                if let mode = file.mode { try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
            } catch {
                throw Failure(message: "Can't write \(file.path): \(error.localizedDescription)")
            }
            paths.append(file.path)
        }
        return paths
    }

    /// `org-babel-tangle`'s message.
    public static func message(_ output: Tangle.Output, source: String) -> String {
        "Tangled \(output.blocks) code block\(output.blocks == 1 ? "" : "s") from \((source as NSString).lastPathComponent)"
    }
}

extension DocumentSession {
    /// Tangles the open file: its text as it is now, written beside it.
    public func tangle(_ scope: Tangle.Scope) -> String {
        guard let path, let document else { return "No file is open" }
        switch Tangle.run(text: document.text, path: path, scope: scope, tree: document.tree) {
        case .failure(.message(let message)):
            return message
        case .success(let output):
            do {
                try TangleWriter.write(output, source: path)
                return TangleWriter.message(output, source: path)
            } catch {
                return error.message
            }
        }
    }
}
