import Foundation
import UniformTypeIdentifiers

/// How a file that isn't org opens: as text in the editor, or as a preview.
enum FileTypes {
    /// Whether the file is text: a text type, or, for unknown types, UTF-8 without NUL
    /// bytes in its first 8 KB.
    static func isText(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic {
            if type.conforms(to: .text) { return true }
            if type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf) || type.conforms(to: .archive) {
                return false
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        if head.contains(0) { return false }
        // A cut multibyte character at the end is still text.
        for trim in 0...3 where head.count >= trim {
            if String(data: head.dropLast(trim), encoding: .utf8) != nil { return true }
        }
        return false
    }

    /// The src block language name the highlighter knows for a file's extension.
    static func language(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension.lowercased() {
        case "sh", "bash", "zsh": return "sh"
        case "py": return "python"
        case "el": return "emacs-lisp"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp", "hh": return "cpp"
        case "r": return "r"
        case "js", "mjs", "cjs": return "js"
        case "java": return "java"
        case "scm", "ss": return "scheme"
        case "clj", "cljs", "cljc", "edn": return "clojure"
        case "hs": return "haskell"
        case "rs": return "rust"
        case "go": return "go"
        case "rb": return "ruby"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "lua": return "lua"
        default:
            return ["zshrc", ".zshrc", "bashrc", ".bashrc", ".profile"].contains(url.lastPathComponent) ? "sh" : nil
        }
    }
}
