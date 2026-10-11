import CryptoKit
import Foundation
import OrgCore

public enum FileKind: String, Sendable {
    case org
    case archive
    /// A Syncthing conflict copy: listed, never indexed for search, agenda or IDs.
    case conflict
    /// Any other file: listed and openable, never read by the index.
    case other
}

/// Everything that decides what an index row means. Bump `version` when a semantic setting
/// changes, so files indexed under the old settings are indexed again.
public struct IndexSettings: Sendable, Equatable {
    public var version: Int
    public var org: OrgSettings
    public var semantic: SemanticSettings

    /// Settings whose version follows the TODO keywords, so changing them reindexes.
    public static func with(todoKeywords org: OrgSettings) -> IndexSettings {
        let names = org.todoSequences.map { ($0.active.map(\.name) + ["|"] + $0.done.map(\.name)).joined(separator: " ") }.joined(separator: ";")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in names.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return IndexSettings(version: 1 + Int(hash % 1_000_000), org: org)
    }

    public init(version: Int = 1, org: OrgSettings = .default, semantic: SemanticSettings = .default) {
        self.version = version
        self.org = org
        self.semantic = semantic
    }
}

public struct TagRow: Sendable, Equatable {
    public let name: String
    public let inherited: Bool
}

public struct PropertyRow: Sendable, Equatable {
    /// Upper-cased.
    public let key: String
    public let value: String
    public let inherited: Bool
}

public struct TimestampRow: Sendable, Equatable {
    public enum Kind: String, Sendable { case scheduled, deadline, closed, active, inactive }
    public let kind: Kind
    /// `2026-10-04` or `2026-10-04T10:00`.
    public let start: String
    public let end: String?
    /// As written: `+1w`, `.+2d/3d`.
    public let repeater: String?
    /// As written: `-2d`, `--1w`.
    public let warning: String?
}

public struct ClockRow: Sendable, Equatable {
    public let start: String
    public let end: String?
    public let minutes: Int?
}

public struct LinkRow: Sendable, Equatable {
    /// The scheme before the first colon (`id`, `file`, `https`), or `fuzzy`.
    public let type: String
    public let target: String
}

public struct HeadingRecord: Sendable, Equatable {
    /// Position in document order; parents refer to it.
    public let ordinal: Int
    public let parent: Int?
    /// The section's UTF-16 range in the file's text.
    public let start: Int
    public let end: Int
    public let level: Int
    public let todo: String?
    public let isDone: Bool
    public let priority: String?
    public let title: String
    public let outlinePath: [String]
    public let orgID: String?
    /// Tagged `ARCHIVE`, directly or by inheritance.
    public let archived: Bool
    /// The heading's own text, without the heading line and child sections.
    public let body: String
    public let tags: [TagRow]
    public let properties: [PropertyRow]
    public let timestamps: [TimestampRow]
    public let clocks: [ClockRow]
    public let links: [LinkRow]
}

/// One file's index rows, computed without touching the database.
public struct FileRecord: Sendable, Equatable {
    public let path: String
    public let root: String
    public let kind: FileKind
    public let size: Int
    public let mtime: Double
    /// SHA-256 of the bytes, hex.
    public let hash: String
    public let settingsVersion: Int
    public let headings: [HeadingRecord]
    /// Links before the first heading, the file's own.
    public let links: [LinkRow]
    /// The `ID` in the property drawer before the first heading: the file as an org-roam node.
    public let fileID: String?
    /// `#+TITLE`, joined with spaces when there are several.
    public let title: String?

    public static func hash(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    public init(path: String, root: String, kind: FileKind, bytes: [UInt8], mtime: Double, settings: IndexSettings) {
        self.path = path
        self.root = root
        self.kind = kind
        self.size = bytes.count
        self.mtime = mtime
        self.hash = Self.hash(bytes)
        let source = SourceText(bytes: bytes)
        var resolved = settings
        resolved.org = settings.org.resolvingSetupFiles(in: source.text, path: path, read: OrgSettings.readFile)
        self.settingsVersion = Self.settingsVersion(settings, text: source.text, setupKeywords: resolved.org.setupKeywords)
        (headings, links, fileID, title) = kind == .conflict ? ([], [], nil, nil) : Self.rows(source.text, settings: resolved)
    }

    /// The settings version a file's rows are built under: the index's, with the keywords of
    /// the setup files it names mixed in, so a changed setup file indexes it again.
    public static func settingsVersion(_ settings: IndexSettings, text: String, setupKeywords: String) -> Int {
        guard text.containsIgnoringASCIICase("#+setupfile:") else { return settings.version }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in setupKeywords.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return settings.version + 1_000_000 * (1 + Int(hash % 1_000_000))
    }

    /// `settingsVersion` for a file's bytes, reading the setup files it names.
    public static func settingsVersion(_ settings: IndexSettings, bytes: [UInt8], path: String) -> Int {
        let text = SourceText(bytes: bytes).text
        guard text.containsIgnoringASCIICase("#+setupfile:") else { return settings.version }
        let keywords = settings.org.resolvingSetupFiles(in: text, path: path, read: OrgSettings.readFile).setupKeywords
        return settingsVersion(settings, text: text, setupKeywords: keywords)
    }

    /// A file the index lists without reading: `hash` stands for its size and mtime.
    public init(path: String, root: String, unreadSize size: Int, mtime: Double, settings: IndexSettings) {
        self.path = path
        self.root = root
        self.kind = .other
        self.size = size
        self.mtime = mtime
        self.hash = Self.unreadHash(size: size, mtime: mtime)
        self.settingsVersion = settings.version
        headings = []
        links = []
        fileID = nil
        title = nil
    }

    public static func unreadHash(size: Int, mtime: Double) -> String { "unread:\(size):\(mtime)" }

    static func rows(_ text: String, settings: IndexSettings) -> (headings: [HeadingRecord], links: [LinkRow], fileID: String?, title: String?) {
        let model = DocumentModel(tree: OrgParser.parse(text, defaults: settings.org), settings: settings.semantic)
        let utf16 = text.utf16
        func slice(_ range: Range<Int>) -> String {
            let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
            let end = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
            return String(text[start..<end])
        }
        var firstChild: [Int: Int] = [:]
        for (index, heading) in model.headings.enumerated() {
            if let parent = heading.parent, firstChild[parent] == nil { firstChild[parent] = index }
        }

        let headings = model.headings.enumerated().map { index, heading in
            let bodyEnd = firstChild[index].map { model.headings[$0].sectionRange.lowerBound } ?? heading.sectionRange.upperBound
            let tags = model.tags(of: index)
            return HeadingRecord(
                ordinal: index,
                parent: heading.parent,
                start: heading.sectionRange.lowerBound,
                end: heading.sectionRange.upperBound,
                level: heading.level,
                todo: heading.todo,
                isDone: heading.isDone,
                priority: heading.priority,
                title: heading.title,
                outlinePath: model.outlinePath(of: index),
                orgID: heading.id,
                archived: tags.contains { $0.value == "ARCHIVE" },
                body: slice(heading.headingRange.upperBound..<bodyEnd),
                tags: tags.map { TagRow(name: $0.value, inherited: $0.source != .heading(index)) },
                properties: properties(model, index),
                timestamps: timestamps(heading),
                clocks: heading.clocks.map {
                    ClockRow(start: format($0.start), end: $0.end.map(format), minutes: $0.minutes)
                },
                links: heading.links.map(linkRow)
            )
        }
        let fileID = model.property("ID", of: nil)?.value.trimmingCharacters(in: .whitespaces)
        let zeroth = model.headings.first.map { slice(0..<$0.sectionRange.lowerBound) } ?? text
        let titles = zeroth.matches(of: /(?im)^[ \t]*#\+title:[ \t]*(.*?)[ \t]*$/).map { String($0.1) }
        return (headings, model.links.map(linkRow), fileID?.isEmpty == false ? fileID : nil, titles.isEmpty ? nil : titles.joined(separator: " "))
    }

    static func linkRow(_ target: String) -> LinkRow {
        let scheme = target.prefix { $0 != ":" }
        let isScheme = scheme.count < target.count && !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0 == "-" }
        return LinkRow(type: isScheme ? scheme.lowercased() : "fuzzy", target: target)
    }

    /// Own properties, plus inherited ones for keys that inherit.
    static func properties(_ model: DocumentModel, _ index: Int) -> [PropertyRow] {
        var keys: [String] = []
        func add(_ entries: [Property], inheritedOnly: Bool) {
            for entry in entries {
                let key = entry.key.uppercased()
                if !keys.contains(key), !inheritedOnly || model.inherits(key) { keys.append(key) }
            }
        }
        add(model.headings[index].properties, inheritedOnly: false)
        add(model.fileProperties, inheritedOnly: true)
        for ancestor in model.ancestors(of: index) { add(model.headings[ancestor].properties, inheritedOnly: true) }
        return keys.compactMap { key in
            model.property(key, of: index).map {
                PropertyRow(key: key, value: $0.value, inherited: $0.source != .heading(index))
            }
        }
    }

    static func timestamps(_ heading: HeadingInfo) -> [TimestampRow] {
        var rows: [TimestampRow] = []
        func add(_ stamp: Timestamp?, _ kind: TimestampRow.Kind) {
            guard let stamp else { return }
            rows.append(TimestampRow(
                kind: kind,
                start: format(stamp.start),
                end: stamp.end.map(format),
                repeater: stamp.repeater.map {
                    $0.kind.rawValue + format($0.interval) + ($0.habitDeadline.map { "/" + format($0) } ?? "")
                },
                warning: stamp.warning.map { ($0.firstOccurrenceOnly ? "--" : "-") + format($0.interval) }
            ))
        }
        add(heading.scheduled, .scheduled)
        add(heading.deadline, .deadline)
        add(heading.closed, .closed)
        for stamp in heading.timestamps { add(stamp, stamp.active ? .active : .inactive) }
        return rows
    }

    static func format(_ point: Timestamp.Point) -> String {
        let date = String(format: "%04d-%02d-%02d", point.year, point.month, point.day)
        guard let hour = point.hour, let minute = point.minute else { return date }
        return date + String(format: "T%02d:%02d", hour, minute)
    }

    static func format(_ interval: Timestamp.Interval) -> String {
        "\(interval.value)\(interval.unit.rawValue)"
    }
}
