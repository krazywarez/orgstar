import Foundation

/// Runs `emacs --batch` for what the native code hands over, such as tables outside the
/// native formula domain.
public enum EmacsRunner {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// `ORGSTAR_EMACS`, then the usual install locations: an app launched from the Dock
    /// doesn't see the shell's PATH.
    public static func executable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let candidates = [environment["ORGSTAR_EMACS"]].compactMap { $0 } + [
            "/opt/homebrew/bin/emacs", "/usr/local/bin/emacs", "/Applications/Emacs.app/Contents/MacOS/Emacs",
            "/run/current-system/sw/bin/emacs", "/usr/bin/emacs",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Emacs point for a UTF-16 offset.
    static func point(_ offset: Int, in text: String) -> Int {
        let index = String.Index(utf16Offset: offset, in: text)
        return text.unicodeScalars[..<index].count + 1
    }

    /// Runs `form` with point at `point` in a copy of `text` whose directory is `directory`,
    /// then returns the text of the table that starts at `table.lowerBound`.
    public static func recalculateTable(text: String, directory: URL, table: Range<Int>, point: Int, form: String, timeout: Duration = .seconds(60)) async throws -> String {
        guard let emacs = executable() else { throw Failure(description: "Emacs isn't installed, so this table can't be recalculated.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-emacs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("input.org")
        let output = folder.appendingPathComponent("output.org")
        let script = folder.appendingPathComponent("recalc.el")
        try text.write(to: input, atomically: true, encoding: .utf8)
        func lisp(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        try """
        ;;; -*- lexical-binding: t -*-
        (require 'org)
        (require 'org-table)
        (setq enable-local-variables :safe)
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents \(lisp(input.path))))
          (setq default-directory \(lisp(directory.path + "/")))
          (org-mode)
          (goto-char \(Self.point(point, in: text)))
          \(form)
          (goto-char \(Self.point(table.lowerBound, in: text)))
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (org-table-begin) (org-table-end) \(lisp(output.path)))))
        """.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = emacs
        process.arguments = ["-Q", "--batch", "-l", script.path]
        process.currentDirectoryURL = directory
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + timeout
        while process.isRunning {
            if ContinuousClock.now > deadline {
                process.terminate()
                throw Failure(description: "Emacs took too long to recalculate the table.")
            }
            try await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
        }
        guard process.terminationStatus == 0, let data = FileManager.default.contents(atPath: output.path) else {
            let log = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let last = log.split(separator: "\n").last.map(String.init) ?? "Emacs failed"
            throw Failure(description: last)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
