import Foundation
@testable import OrgCore

/// Runs cases through `emacs -Q --batch` with Org's settings pinned, so commands can be
/// compared with Emacs byte for byte. One Emacs process runs a whole batch.
///
/// Pinned versions: Emacs 31.1, Org 9.8.7 (design, "Testing"). `ORGSTAR_EMACS` overrides the
/// executable.
enum EmacsOracle {
    struct Case: Codable {
        var text: String
        /// Emacs point: 1 plus the number of characters (code points) before it.
        var point: Int
        /// An Emacs Lisp form to run with point there.
        var form: String
    }

    struct Result: Codable, Equatable {
        var text: String
        var point: Int
        /// The error message, or empty.
        var error: String
    }

    static let script = #"""
    ;;; -*- lexical-binding: t -*-
    (require 'org)
    (require 'json)
    (require 'cl-lib)
    (setq org-todo-keywords '((sequence "TODO" "DONE"))
          org-log-done nil
          org-log-repeat nil
          org-adapt-indentation nil
          org-tags-column -77
          org-priority-highest ?A
          org-priority-lowest ?C
          org-priority-default ?B)
    ;; Buffer-local when set, so set the default for the case buffers.
    (setq-default indent-tabs-mode nil)
    ;; Archive files open in Org mode, as in usual configurations.
    (add-to-list 'auto-mode-alist '("\\.org_archive\\'" . org-mode))
    (let* ((input (with-temp-buffer
                    (let ((coding-system-for-read 'utf-8-unix))
                      (insert-file-contents (getenv "ORACLE_INPUT")))
                    (json-parse-buffer :object-type 'alist :array-type 'list)))
           (results nil))
      (dolist (c input)
        (with-temp-buffer
          (insert (alist-get 'text c))
          (org-mode)
          ;; `#+STARTUP' may fold the buffer; cases run with everything visible.
          (org-fold-show-all)
          (goto-char (alist-get 'point c))
          ;; As an interactive call, not a repeat: some commands cycle differently on repeats.
          (setq this-command 'orgstar-oracle last-command nil)
          (let ((err (condition-case e
                         (progn (eval (car (read-from-string (alist-get 'form c))) t) "")
                       (error (error-message-string e)))))
            (push `((text . ,(buffer-substring-no-properties (point-min) (point-max)))
                    (point . ,(point))
                    (error . ,err))
                  results))))
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file (getenv "ORACLE_OUTPUT")
          (insert (json-encode (nreverse results))))))
    """#

    static var executable: String { ProcessInfo.processInfo.environment["ORGSTAR_EMACS"] ?? "emacs" }

    static var isAvailable: Bool {
        (try? run(["--version"]))?.contains("GNU Emacs") ?? false
    }

    static func run(_ cases: [Case]) throws -> [Result] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let scriptURL = folder.appendingPathComponent("oracle.el")
        let input = folder.appendingPathComponent("input.json")
        let output = folder.appendingPathComponent("output.json")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try JSONEncoder().encode(cases).write(to: input)
        _ = try run(["-Q", "--batch", "-l", scriptURL.path], environment: ["ORACLE_INPUT": input.path, "ORACLE_OUTPUT": output.path, "TZ": "UTC"])
        return try JSONDecoder().decode([Result].self, from: Data(contentsOf: output))
    }

    @discardableResult
    static func run(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// UTF-16 offset to Emacs point.
    static func point(_ offset: Int, in text: String) -> Int {
        let index = String.Index(utf16Offset: offset, in: text)
        return text.unicodeScalars[..<index].count + 1
    }

    /// Emacs point to UTF-16 offset.
    static func offset(_ point: Int, in text: String) -> Int {
        text.unicodeScalars.prefix(point - 1).reduce(0) { $0 + $1.utf16.count }
    }

    /// UTF-16 offsets of every unicode scalar boundary, including the end.
    static func positions(_ text: String) -> [Int] {
        var positions = [0]
        var offset = 0
        for scalar in text.unicodeScalars {
            offset += scalar.utf16.count
            positions.append(offset)
        }
        return positions
    }
}

/// The options as Emacs Lisp bindings around `form`.
func withOptions(_ options: EditingOptions, _ form: String) -> String {
    func flag(_ value: Bool) -> String { value ? "t" : "nil" }
    return "(let ((org-tags-column \(options.tagsColumn)) (org-insert-heading-respect-content \(flag(options.insertHeadingRespectContent))) (org-M-RET-may-split-line \(flag(options.metaReturnMaySplitLine))) (org-list-allow-alphabetical \(flag(options.listAllowAlphabetical)))) \(form))"
}

/// The options in the user's Doom Emacs.
let doomOptions = EditingOptions(tagsColumn: 0, insertHeadingRespectContent: true, metaReturnMaySplitLine: false, listAllowAlphabetical: true)

/// Runs a command the way an editor would: build a context, run, apply the edits.
func runCommand(_ command: any OrgCommand, _ text: String, caret: Int, answers: [String: String] = [:], options: EditingOptions = .org) -> (text: String, caret: Int, failure: String?) {
    let context = EditContext(revision: 0, text: text, tree: OrgParser.parse(text), selection: [caret..<caret], answers: answers, options: options)
    switch command.run(in: context) {
    case .commit(let result):
        var new = text
        for edit in result.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { new = edit.apply(to: new) }
        return (new, result.selection?.first?.lowerBound ?? caret, nil)
    case .failed(let message):
        return (text, caret, message)
    case .prompt(let prompt):
        return (text, caret, "prompt: \(prompt.key)")
    }
}
