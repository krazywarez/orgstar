import Foundation
import OrgPresentation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterClojure
import TreeSitterElisp
import TreeSitterGo
import TreeSitterHaskell
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterLua
import TreeSitterPython
import TreeSitterR
import TreeSitterRuby
import TreeSitterRust
import TreeSitterScheme
import TreeSitterYAML

/// Src block highlighting with tree-sitter grammars and their own highlight queries.
public final class TreeSitterHighlighter: CodeHighlighter, @unchecked Sendable {
    private struct Grammar {
        let language: Language
        let query: Query
    }

    private let lock = NSLock()
    private var grammars: [String: Grammar?] = [:]
    private var cache: [String: [(range: Range<Int>, category: SyntaxCategory)]] = [:]

    public init() {}

    /// The grammar for an org src block language name, as `org-src-lang-modes` maps them.
    static func grammarName(for language: String) -> String? {
        switch language.lowercased() {
        case "sh", "bash", "shell", "zsh": "bash"
        case "python", "python3", "py": "python"
        case "emacs-lisp", "elisp": "elisp"
        case "c": "c"
        case "c++", "cpp": "cpp"
        case "r": "r"
        case "js", "javascript", "node": "javascript"
        case "java": "java"
        case "scheme": "scheme"
        case "clojure", "clj": "clojure"
        case "haskell": "haskell"
        case "rust": "rust"
        case "go": "go"
        case "ruby": "ruby"
        case "json": "json"
        case "yaml", "yml": "yaml"
        case "lua": "lua"
        default: nil
        }
    }

    private static func pointer(for name: String) -> OpaquePointer? {
        switch name {
        case "bash": tree_sitter_bash()
        case "c": tree_sitter_c()
        case "clojure": tree_sitter_clojure()
        case "cpp": tree_sitter_cpp()
        case "elisp": tree_sitter_elisp()
        case "go": tree_sitter_go()
        case "haskell": tree_sitter_haskell()
        case "java": tree_sitter_java()
        case "javascript": tree_sitter_javascript()
        case "json": tree_sitter_json()
        case "lua": tree_sitter_lua()
        case "python": tree_sitter_python()
        case "r": tree_sitter_r()
        case "ruby": tree_sitter_ruby()
        case "rust": tree_sitter_rust()
        case "scheme": tree_sitter_scheme()
        case "yaml": tree_sitter_yaml()
        default: nil
        }
    }

    /// Compiled once per language; nil when the language or its query can't be loaded.
    private func grammar(_ name: String) -> Grammar? {
        if let known = grammars[name] { return known }
        var grammar: Grammar?
        if let pointer = Self.pointer(for: name), let source = HighlightQueries.source[name] {
            let language = Language(pointer)
            if let query = try? Query(language: language, data: Data(source.utf8)) {
                grammar = Grammar(language: language, query: query)
            }
        }
        grammars[name] = grammar
        return grammar
    }

    public func highlights(language: String, code: String) -> [(range: Range<Int>, category: SyntaxCategory)] {
        guard let name = Self.grammarName(for: language) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let key = name + "\u{0}" + code
        if let cached = cache[key] { return cached }
        guard let grammar = grammar(name) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar.language)) != nil, let tree = parser.parse(code) else { return [] }
        let context = Predicate.Context(string: code)
        var runs: [(range: Range<Int>, category: SyntaxCategory)] = []
        // Query patterns come in priority order, first match first; reversed, so the first
        // pattern for a node is applied last and wins.
        var matches: [QueryMatch] = []
        for match in grammar.query.execute(in: tree) where match.allowed(in: context) { matches.append(match) }
        for match in matches {
            for capture in match.captures {
                guard let name = capture.name, let category = SyntaxCategory(capture: name) else { continue }
                let range = capture.range
                runs.append((range.location..<NSMaxRange(range), category))
            }
        }
        var seen = Set<Range<Int>>()
        var result: [(range: Range<Int>, category: SyntaxCategory)] = []
        for run in runs where seen.insert(run.range).inserted { result.append(run) }
        result.reverse()
        if cache.count > 512 { cache.removeAll() }
        cache[key] = result
        return result
    }
}
