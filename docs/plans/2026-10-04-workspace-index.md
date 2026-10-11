# Workspace and Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SQLite index of every org file under the user's folders, kept in line with the files by reconciliation scans that FSEvents batches trigger, with full-text search, ID lookup and an overlay for unsaved buffers.

**Architecture:** Two targets. `OrgIndex` turns a file's bytes into a `FileRecord` (pure, no database), stores records with GRDB, and answers queries; every query takes an overlay of records for unsaved buffers that replace those files' rows. `OrgWorkspace` classifies and scans folders, decides agenda membership, reconciles a root (or a batch of changed paths) against the index with rename detection, and wraps FSEvents. File events are only hints: reconciliation compares size, mtime, hash and settings version, and is safe to run at any time.

**Tech Stack:** Swift 6.2 tools, Swift Testing, GRDB 7.11 (SQLite with FTS5), CryptoKit, CoreServices (FSEvents, macOS only).

**Spec:** `docs/design.md`, "Workspace, storage and index".

## Global Constraints

- The index is a cache; nothing exists only in it.
- Syncthing conflict copies are listed but never indexed for search, agenda or IDs.
- Index rows record the settings version; a new version reindexes.
- Query results carry the content hash their offsets refer to.
- Gates (design, "Phases"): full rebuild of 10,000 files under 30 s; reconciliation with no changes under 2 s.

## Out of scope

Agenda queries (phase 3), security-scoped bookmark creation in a sandbox (the Mac app is unsandboxed; iOS adds it), `NSFilePresenter`/`NSMetadataQuery` watching on iOS, and conflict UI.

## File structure

| File | Responsibility |
| --- | --- |
| `Package.swift` | `OrgIndex` (GRDB) and `OrgWorkspace` targets |
| `Sources/OrgIndex/FileRecord.swift` | `FileRecord` and its row types, built from bytes |
| `Sources/OrgIndex/IndexStore.swift` | Schema, transactional writes, search, IDs, overlay |
| `Sources/OrgWorkspace/Discovery.swift` | `WorkspaceRoot`, file classification, scanning, `AgendaScope` |
| `Sources/OrgWorkspace/Reconciler.swift` | Index reconciliation with touches, moves and removals |
| `Sources/OrgWorkspace/FSEventsWatcher.swift` | File-level FSEvents with rescan events |

---

### Task 1: File records

**Files:**
- Modify: `Package.swift` (add `OrgIndex` and GRDB)
- Create: `Sources/OrgIndex/FileRecord.swift`
- Test: `Tests/OrgIndexTests/FileRecordTests.swift`

**Interfaces:**
- Consumes: `OrgParser`, `DocumentModel`, `SourceText`, `Timestamp`.
- Produces: `FileKind`, `IndexSettings(version:org:semantic:)`, `FileRecord(path:root:kind:bytes:mtime:settings:)`, `FileRecord.hash(_:)`, `HeadingRecord`, `TagRow`, `PropertyRow`, `TimestampRow`, `ClockRow`, `LinkRow`.

- [x] **Step 1: Add the target**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"]),
        .library(name: "OrgDocument", targets: ["OrgDocument"]),
        .library(name: "OrgIndex", targets: ["OrgIndex"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1")
    ],
    targets: [
        .target(name: "OrgCore"),
        .target(name: "OrgDocument", dependencies: ["OrgCore"]),
        .target(name: "OrgIndex", dependencies: ["OrgCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"]),
        .testTarget(name: "OrgDocumentTests", dependencies: ["OrgDocument"]),
        .testTarget(name: "OrgIndexTests", dependencies: ["OrgIndex"])
    ]
)
```

- [x] **Step 2: Write the failing tests**

```swift
import OrgCore
import Testing
@testable import OrgIndex

func record(_ path: String, _ text: String, kind: FileKind = .org, settings: IndexSettings = IndexSettings()) -> FileRecord {
    FileRecord(path: path, root: "/notes", kind: kind, bytes: Array(text.utf8), mtime: 1, settings: settings)
}

struct FileRecordTests {
    let text = """
    #+FILETAGS: :work:
    #+PROPERTY: OWNER team
    * TODO [#A] Plan the launch :big:
    SCHEDULED: <2026-10-05 Mon +1w -2d>
    :PROPERTIES:
    :ID: plan
    :CATEGORY: launch
    :END:
    Draft the [[https://example.com][brief]] and see [[id:other]].
    ** DONE Child
    CLOSED: [2026-10-04 Sun 09:00]
    :LOGBOOK:
    CLOCK: [2026-10-04 Sun 08:00]--[2026-10-04 Sun 09:00] =>  1:00
    :END:
    <2026-10-06 Tue>

    """

    @Test func headings() throws {
        let headings = record("/notes/a.org", text).headings
        #expect(headings.count == 2)
        let plan = headings[0]
        #expect(plan.todo == "TODO" && !plan.isDone && plan.priority == "A")
        #expect(plan.orgID == "plan")
        #expect(plan.outlinePath == ["Plan the launch"])
        #expect(plan.body.contains("Draft the"))
        #expect(!plan.body.contains("Child"))
        #expect(plan.tags == [TagRow(name: "work", inherited: true), TagRow(name: "big", inherited: false)])
        #expect(plan.links == [LinkRow(type: "https", target: "https://example.com"), LinkRow(type: "id", target: "id:other")])
        #expect(plan.timestamps == [TimestampRow(kind: .scheduled, start: "2026-10-05", end: nil, repeater: "+1w", warning: "-2d")])

        let child = headings[1]
        #expect(child.parent == 0 && child.isDone)
        #expect(child.outlinePath == ["Plan the launch", "Child"])
        #expect(child.tags.map(\.name) == ["work", "big"])
        #expect(child.clocks == [ClockRow(start: "2026-10-04T08:00", end: "2026-10-04T09:00", minutes: 60)])
        #expect(child.timestamps.map(\.kind) == [.closed, .active])
        #expect(child.properties == [PropertyRow(key: "CATEGORY", value: "launch", inherited: true)])
    }

    @Test func propertyInheritanceFollowsSettings() {
        let settings = IndexSettings(semantic: SemanticSettings(propertyInheritance: .all))
        let child = record("/notes/a.org", text, settings: settings).headings[1]
        #expect(child.properties.contains(PropertyRow(key: "OWNER", value: "team", inherited: true)))
    }

    @Test func archiveTag() {
        let headings = record("/notes/a.org", "* a :ARCHIVE:\n** b\n* c\n").headings
        #expect(headings.map(\.archived) == [true, true, false])
    }

    @Test func conflictCopiesHaveNoHeadings() {
        #expect(record("/notes/a.sync-conflict-1.org", "* a\n", kind: .conflict).headings.isEmpty)
    }
}
```

- [x] **Step 3: Implement**

```swift
import CryptoKit
import Foundation
import OrgCore

public enum FileKind: String, Sendable {
    case org
    case archive
    /// A Syncthing conflict copy: listed, never indexed for search, agenda or IDs.
    case conflict
}

/// Everything that decides what an index row means. Bump `version` when a semantic setting
/// changes, so files indexed under the old settings are indexed again.
public struct IndexSettings: Sendable, Equatable {
    public var version: Int
    public var org: OrgSettings
    public var semantic: SemanticSettings

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
        self.settingsVersion = settings.version
        let source = SourceText(bytes: bytes)
        headings = kind == .conflict ? [] : Self.headings(source.text, settings: settings)
    }

    static func headings(_ text: String, settings: IndexSettings) -> [HeadingRecord] {
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

        return model.headings.enumerated().map { index, heading in
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
                links: heading.links.map { target in
                    let scheme = target.prefix { $0 != ":" }
                    let isScheme = scheme.count < target.count && !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0 == "-" }
                    return LinkRow(type: isScheme ? scheme.lowercased() : "fuzzy", target: target)
                }
            )
        }
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
```

- [x] **Step 4: Run to verify pass, then commit**

Run: `swift test --filter FileRecordTests`

```bash
git add Package.swift Package.resolved Sources/OrgIndex/FileRecord.swift Tests/OrgIndexTests/FileRecordTests.swift
git commit -m "Add index file records"
```

---

### Task 2: Index store

**Files:**
- Create: `Sources/OrgIndex/IndexStore.swift`
- Test: `Tests/OrgIndexTests/IndexStoreTests.swift`

**Interfaces:**
- Consumes: `FileRecord` (Task 1).
- Produces: `IndexStore(path:)`, `write(_:)`, `apply(_ change: IndexChange)`, `fileStates(root:) -> [String: FileState]`, `files()`, `search(_:overlay:limit:)`, `headings(withID:overlay:)`, `duplicateIDs(overlay:)`; `FileState`, `HeadingLocation`, `IndexChange`.

- [x] **Step 1: Write the failing tests**

```swift
import OrgCore
import Testing
@testable import OrgIndex

struct IndexStoreTests {
    @Test func searchFindsTitlesAndBodies() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Groceries\nbuy apples\n* Taxes\nfile forms\n"))
        #expect(try store.search("appl").map(\.title) == ["Groceries"])
        #expect(try store.search("tax").map(\.title) == ["Taxes"])
        #expect(try store.search("file forms").map(\.title) == ["Taxes"])
        #expect(try store.search("\"oops").isEmpty)
        #expect(try store.search("   ").isEmpty)
    }

    @Test func rewritingAFileReplacesItsRows() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Old title\n"))
        try store.write(record("/notes/a.org", "* New title\n"))
        #expect(try store.search("old").isEmpty)
        #expect(try store.search("new").count == 1)
    }

    @Test func removeMoveAndTouch() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Alpha\n"))
        try store.write(record("/notes/b.org", "* Beta\n"))
        var change = IndexChange()
        change.removals = ["/notes/a.org"]
        change.moves = [(from: "/notes/b.org", to: "/notes/c.org", mtime: 5)]
        try store.apply(change)
        #expect(try store.search("alpha").isEmpty)
        #expect(try store.search("beta").map(\.path) == ["/notes/c.org"])
        #expect(try store.fileStates(root: "/notes")["/notes/c.org"]?.mtime == 5)
    }

    @Test func overlayReplacesIndexedRows() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* Saved title\n"))
        let overlay = ["/notes/a.org": record("/notes/a.org", "* Unsaved title\n")]
        #expect(try store.search("saved", overlay: overlay).isEmpty)
        #expect(try store.search("unsaved", overlay: overlay).map(\.title) == ["Unsaved title"])
    }

    @Test func idsAndDuplicates() throws {
        let store = try IndexStore()
        try store.write(record("/notes/a.org", "* A\n:PROPERTIES:\n:ID: x\n:END:\n"))
        try store.write(record("/notes/b.org", "* B\n:PROPERTIES:\n:ID: y\n:END:\n"))
        #expect(try store.headings(withID: "x").map(\.path) == ["/notes/a.org"])
        #expect(try store.duplicateIDs().isEmpty)
        let overlay = ["/notes/b.org": record("/notes/b.org", "* B\n:PROPERTIES:\n:ID: x\n:END:\n")]
        #expect(try store.headings(withID: "x", overlay: overlay).map(\.path) == ["/notes/a.org", "/notes/b.org"])
        #expect(try store.duplicateIDs(overlay: overlay).keys.sorted() == ["x"])
    }

    @Test func fileStatesAndKinds() throws {
        let store = try IndexStore()
        let a = record("/notes/a.org", "* A\n")
        try store.write(a)
        try store.write(record("/notes/a.sync-conflict-1.org", "* A\n", kind: .conflict))
        let states = try store.fileStates(root: "/notes")
        #expect(states["/notes/a.org"] == FileState(kind: .org, size: a.size, mtime: 1, hash: a.hash, settingsVersion: 1))
        #expect(try store.files().map(\.kind) == [.org, .conflict])
        #expect(try store.search("a").map(\.path) == ["/notes/a.org"])
    }
}
```

- [x] **Step 2: Implement**

```swift
import Foundation
import GRDB

/// What the index knows about a file without reading it.
public struct FileState: Sendable, Equatable {
    public let kind: FileKind
    public let size: Int
    public let mtime: Double
    public let hash: String
    public let settingsVersion: Int
}

/// A heading as found by a query. `contentHash` is the hash of the text the offsets refer to,
/// so a caller can tell whether they still apply to an open buffer.
public struct HeadingLocation: Sendable, Equatable {
    public let path: String
    public let ordinal: Int
    public let title: String
    public let start: Int
    public let contentHash: String
}

/// One reconciliation's worth of changes, applied in a single transaction.
public struct IndexChange: Sendable {
    public var records: [FileRecord] = []
    /// Unchanged content with a new modification time.
    public var touches: [(path: String, mtime: Double)] = []
    /// Renamed files whose content didn't change.
    public var moves: [(from: String, to: String, mtime: Double)] = []
    public var removals: [String] = []

    public init() {}

    public var isEmpty: Bool { records.isEmpty && touches.isEmpty && moves.isEmpty && removals.isEmpty }
}

/// The SQLite index. A cache: deleting it loses nothing that the files don't hold.
public final class IndexStore: Sendable {
    let database: DatabaseQueue

    /// `path` nil opens an in-memory index.
    public init(path: String? = nil) throws {
        database = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try Self.migrator.migrate(database)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE files (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    root TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    hash TEXT NOT NULL,
                    settings_version INTEGER NOT NULL,
                    parsed_at REAL NOT NULL
                );
                CREATE INDEX files_root ON files(root);
                CREATE TABLE headings (
                    id INTEGER PRIMARY KEY,
                    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    parent_ordinal INTEGER,
                    start_offset INTEGER NOT NULL,
                    end_offset INTEGER NOT NULL,
                    level INTEGER NOT NULL,
                    todo TEXT,
                    is_done INTEGER NOT NULL,
                    priority TEXT,
                    title TEXT NOT NULL,
                    outline_path TEXT NOT NULL,
                    org_id TEXT,
                    archived INTEGER NOT NULL
                );
                CREATE INDEX headings_file ON headings(file_id);
                CREATE INDEX headings_org_id ON headings(org_id);
                CREATE TABLE tags (
                    heading_id INTEGER NOT NULL REFERENCES headings(id) ON DELETE CASCADE,
                    tag TEXT NOT NULL,
                    inherited INTEGER NOT NULL
                );
                CREATE INDEX tags_heading ON tags(heading_id);
                CREATE TABLE properties (
                    heading_id INTEGER NOT NULL REFERENCES headings(id) ON DELETE CASCADE,
                    key TEXT NOT NULL,
                    value TEXT NOT NULL,
                    inherited INTEGER NOT NULL
                );
                CREATE INDEX properties_heading ON properties(heading_id);
                CREATE TABLE timestamps (
                    heading_id INTEGER NOT NULL REFERENCES headings(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    start_at TEXT NOT NULL,
                    end_at TEXT,
                    repeater TEXT,
                    warning TEXT
                );
                CREATE INDEX timestamps_heading ON timestamps(heading_id);
                CREATE TABLE clocks (
                    heading_id INTEGER NOT NULL REFERENCES headings(id) ON DELETE CASCADE,
                    start_at TEXT NOT NULL,
                    end_at TEXT,
                    minutes INTEGER
                );
                CREATE INDEX clocks_heading ON clocks(heading_id);
                CREATE TABLE links (
                    heading_id INTEGER NOT NULL REFERENCES headings(id) ON DELETE CASCADE,
                    type TEXT NOT NULL,
                    target TEXT NOT NULL
                );
                CREATE INDEX links_heading ON links(heading_id);
                CREATE VIRTUAL TABLE headings_fts USING fts5(title, body, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TRIGGER headings_fts_delete AFTER DELETE ON headings BEGIN
                    DELETE FROM headings_fts WHERE rowid = old.id;
                END;
                """)
        }
        return migrator
    }

    // MARK: - Writing

    public func write(_ record: FileRecord) throws {
        var change = IndexChange()
        change.records = [record]
        try apply(change)
    }

    public func apply(_ change: IndexChange) throws {
        guard !change.isEmpty else { return }
        try database.write { db in
            for path in change.removals {
                try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [path])
            }
            for move in change.moves {
                try db.execute(sql: "UPDATE files SET path = ?, mtime = ? WHERE path = ?", arguments: [move.to, move.mtime, move.from])
            }
            for touch in change.touches {
                try db.execute(sql: "UPDATE files SET mtime = ? WHERE path = ?", arguments: [touch.mtime, touch.path])
            }
            for record in change.records {
                try insert(record, db)
            }
        }
    }

    private func insert(_ record: FileRecord, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM files WHERE path = ?", arguments: [record.path])
        try db.execute(
            sql: """
                INSERT INTO files (path, root, kind, size, mtime, hash, settings_version, parsed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [record.path, record.root, record.kind.rawValue, record.size, record.mtime, record.hash,
                        record.settingsVersion, Date().timeIntervalSince1970]
        )
        let fileID = db.lastInsertedRowID
        for heading in record.headings {
            try db.execute(
                sql: """
                    INSERT INTO headings (file_id, ordinal, parent_ordinal, start_offset, end_offset, level, todo,
                                          is_done, priority, title, outline_path, org_id, archived)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [fileID, heading.ordinal, heading.parent, heading.start, heading.end, heading.level, heading.todo,
                            heading.isDone, heading.priority, heading.title, heading.outlinePath.joined(separator: "\u{1F}"),
                            heading.orgID, heading.archived]
            )
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO headings_fts (rowid, title, body) VALUES (?, ?, ?)", arguments: [id, heading.title, heading.body])
            for tag in heading.tags {
                try db.execute(sql: "INSERT INTO tags VALUES (?, ?, ?)", arguments: [id, tag.name, tag.inherited])
            }
            for property in heading.properties {
                try db.execute(sql: "INSERT INTO properties VALUES (?, ?, ?, ?)", arguments: [id, property.key, property.value, property.inherited])
            }
            for stamp in heading.timestamps {
                try db.execute(
                    sql: "INSERT INTO timestamps VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [id, stamp.kind.rawValue, stamp.start, stamp.end, stamp.repeater, stamp.warning]
                )
            }
            for clock in heading.clocks {
                try db.execute(sql: "INSERT INTO clocks VALUES (?, ?, ?, ?)", arguments: [id, clock.start, clock.end, clock.minutes])
            }
            for link in heading.links {
                try db.execute(sql: "INSERT INTO links VALUES (?, ?, ?)", arguments: [id, link.type, link.target])
            }
        }
    }

    // MARK: - Reading

    /// Indexed files under `root`, by path.
    public func fileStates(root: String) throws -> [String: FileState] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT path, kind, size, mtime, hash, settings_version FROM files WHERE root = ?", arguments: [root])
            var states: [String: FileState] = [:]
            for row in rows {
                states[row["path"]] = FileState(
                    kind: FileKind(rawValue: row["kind"]) ?? .org,
                    size: row["size"], mtime: row["mtime"], hash: row["hash"], settingsVersion: row["settings_version"]
                )
            }
            return states
        }
    }

    public func files() throws -> [(path: String, kind: FileKind)] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT path, kind FROM files ORDER BY path").map {
                (path: $0["path"], kind: FileKind(rawValue: $0["kind"]) ?? .org)
            }
        }
    }

    // MARK: - Queries
    //
    // `overlay` holds records for open documents with unsaved edits, keyed by path. Their rows
    // replace that file's indexed rows in every query.

    /// Headings whose title or body contain every word of `query` as a word prefix.
    public func search(_ query: String, overlay: [String: FileRecord] = [:], limit: Int = 50) throws -> [HeadingLocation] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " ")
        let indexed = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.path, f.hash, h.ordinal, h.title, h.start_offset
                    FROM headings_fts
                    JOIN headings h ON h.id = headings_fts.rowid
                    JOIN files f ON f.id = h.file_id
                    WHERE headings_fts MATCH ?
                    ORDER BY bm25(headings_fts)
                    LIMIT ?
                    """,
                arguments: [match, limit + overlay.count * 10]
            ).map(location)
        }
        // Unsaved buffers get the same word-prefix matching as the full-text index.
        let prefixes = terms.flatMap(Self.words)
        let live = overlay.values.sorted { $0.path < $1.path }.flatMap { record in
            record.headings.filter { heading in
                let words = Self.words(heading.title + "\n" + heading.body)
                return prefixes.allSatisfy { prefix in words.contains { $0.hasPrefix(prefix) } }
            }.map { location(record, $0) }
        }
        return Array((live + indexed.filter { overlay[$0.path] == nil }).prefix(limit))
    }

    /// Headings with `:ID: id`. More than one means the ID is duplicated.
    public func headings(withID id: String, overlay: [String: FileRecord] = [:]) throws -> [HeadingLocation] {
        let indexed = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.path, f.hash, h.ordinal, h.title, h.start_offset
                    FROM headings h JOIN files f ON f.id = h.file_id
                    WHERE h.org_id = ? ORDER BY f.path, h.ordinal
                    """,
                arguments: [id]
            ).map(location)
        }
        let live = overlay.values.sorted { $0.path < $1.path }.flatMap { record in
            record.headings.filter { $0.orgID == id }.map { location(record, $0) }
        }
        return indexed.filter { overlay[$0.path] == nil } + live
    }

    /// IDs used by more than one heading.
    public func duplicateIDs(overlay: [String: FileRecord] = [:]) throws -> [String: [HeadingLocation]] {
        let indexed = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT h.org_id, f.path, f.hash, h.ordinal, h.title, h.start_offset
                    FROM headings h JOIN files f ON f.id = h.file_id
                    WHERE h.org_id IN (SELECT org_id FROM headings WHERE org_id IS NOT NULL GROUP BY org_id HAVING count(*) > 1)
                       OR (h.org_id IS NOT NULL AND ? > 0)
                    ORDER BY f.path, h.ordinal
                    """,
                arguments: [overlay.count]
            ).map { (id: $0["org_id"] as String, location: location($0)) }
        }
        var byID: [String: [HeadingLocation]] = [:]
        for row in indexed where overlay[row.location.path] == nil {
            byID[row.id, default: []].append(row.location)
        }
        for record in overlay.values.sorted(by: { $0.path < $1.path }) {
            for heading in record.headings {
                if let id = heading.orgID { byID[id, default: []].append(location(record, heading)) }
            }
        }
        return byID.filter { $0.value.count > 1 }
    }

    /// Lower-cased runs of letters and digits, as the unicode61 tokenizer splits them.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func location(_ row: Row) -> HeadingLocation {
        HeadingLocation(path: row["path"], ordinal: row["ordinal"], title: row["title"], start: row["start_offset"], contentHash: row["hash"])
    }

    private func location(_ record: FileRecord, _ heading: HeadingRecord) -> HeadingLocation {
        HeadingLocation(path: record.path, ordinal: heading.ordinal, title: heading.title, start: heading.start, contentHash: record.hash)
    }
}
```

- [x] **Step 3: Run to verify pass, then commit**

Run: `swift test --filter IndexStoreTests`

```bash
git add Sources/OrgIndex/IndexStore.swift Tests/OrgIndexTests/IndexStoreTests.swift
git commit -m "Add SQLite index store with search and overlay"
```

---

### Task 3: Discovery and agenda scope

**Files:**
- Modify: `Package.swift` (add `OrgWorkspace`)
- Create: `Sources/OrgWorkspace/Discovery.swift`
- Test: `Tests/OrgWorkspaceTests/Folder.swift`, `Tests/OrgWorkspaceTests/DiscoveryTests.swift`

**Interfaces:**
- Consumes: `FileKind` (Task 1).
- Produces: `WorkspaceRoot(url:)` with `resolve()`, `DiscoveredFile`, `Discovery`, `FileClassification`, `WorkspaceScanner.classify(_:)`, `WorkspaceScanner.scan(_:)`, `AgendaScope(globs:)` with `contains(relativePath:kind:)`; test helper `Folder`.

- [x] **Step 1: Add the target**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Orgstar",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "OrgCore", targets: ["OrgCore"]),
        .library(name: "OrgDocument", targets: ["OrgDocument"]),
        .library(name: "OrgIndex", targets: ["OrgIndex"]),
        .library(name: "OrgWorkspace", targets: ["OrgWorkspace"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1")
    ],
    targets: [
        .target(name: "OrgCore"),
        .target(name: "OrgDocument", dependencies: ["OrgCore"]),
        .target(name: "OrgIndex", dependencies: ["OrgCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "OrgWorkspace", dependencies: ["OrgIndex"]),
        .testTarget(name: "OrgCoreTests", dependencies: ["OrgCore"]),
        .testTarget(name: "OrgDocumentTests", dependencies: ["OrgDocument"]),
        .testTarget(name: "OrgIndexTests", dependencies: ["OrgIndex"]),
        .testTarget(name: "OrgWorkspaceTests", dependencies: ["OrgWorkspace"])
    ]
)
```

- [x] **Step 2: Write the failing tests**

```swift
import Foundation

/// A temporary folder that removes itself.
final class Folder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("orgstar-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file.standardizedFileURL
    }
}
```

```swift
import Foundation
import OrgIndex
import Testing
@testable import OrgWorkspace

struct ClassificationTests {
    @Test(arguments: [
        ("a.org", FileClassification.file(.org)),
        ("a.org_archive", .file(.archive)),
        ("a.sync-conflict-20261004-120000-ABCDEFG.org", .file(.conflict)),
        (".a.org.icloud", .placeholder("a.org")),
        (".syncthing.a.org.tmp", .ignored),
        (".a.org.orgstar-1234", .ignored),
        ("a.org~", .ignored),
        ("#a.org#", .ignored),
        ("a.md", .ignored),
        (".hidden.org", .ignored),
    ])
    func classify(name: String, expected: FileClassification) {
        #expect(WorkspaceScanner.classify(name) == expected)
    }

    @Test func agendaScope() {
        #expect(AgendaScope().contains(relativePath: "a.org", kind: .org))
        #expect(!AgendaScope().contains(relativePath: "a.org_archive", kind: .archive))
        #expect(!AgendaScope().contains(relativePath: "a.org", kind: .conflict))
        let work = AgendaScope(globs: ["work/*"])
        #expect(work.contains(relativePath: "work/deep/a.org", kind: .org))
        #expect(!work.contains(relativePath: "home/a.org", kind: .org))
    }
}

struct ScanTests {
    @Test func skipsHiddenFoldersAndFindsPlaceholders() throws {
        let folder = try Folder()
        try folder.write("a.org", "* a\n")
        try folder.write("sub/b.org_archive", "* b\n")
        try folder.write(".git/c.org", "* c\n")
        try folder.write(".stversions/d.org", "* d\n")
        try folder.write("sub/.e.org.icloud", "")
        try folder.write("notes.txt", "")
        let discovery = try WorkspaceScanner.scan(folder.url)
        #expect(discovery.files.map(\.url.lastPathComponent) == ["a.org", "b.org_archive"])
        #expect(discovery.placeholders.map(\.lastPathComponent) == ["e.org"])
    }
}
```

- [x] **Step 3: Implement**

```swift
import Foundation
import OrgIndex

/// A folder the user added. Identified by its bookmark, so a moved folder is followed.
public struct WorkspaceRoot: Sendable, Equatable, Codable {
    public let bookmark: Data
    /// The path when the bookmark was made or last refreshed, for display.
    public var path: String

    public init(url: URL) throws {
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        path = url.standardizedFileURL.path
    }

    /// The folder's current location. `isStale` means the bookmark should be made again.
    public func resolve() throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        _ = url.startAccessingSecurityScopedResource()
        return (url.standardizedFileURL, isStale)
    }
}

public struct DiscoveredFile: Sendable, Equatable {
    public let url: URL
    public let kind: FileKind
    public let size: Int
    public let mtime: Double
}

public struct Discovery: Sendable, Equatable {
    public var files: [DiscoveredFile] = []
    /// iCloud files not downloaded yet, by the name they will have.
    public var placeholders: [URL] = []
}

public enum FileClassification: Sendable, Equatable {
    case file(FileKind)
    /// An iCloud placeholder (`.name.org.icloud`) for the file at the given name.
    case placeholder(String)
    case ignored
}

public enum WorkspaceScanner {
    /// What a file name means to the workspace. Syncthing temp files, our own temp and backup
    /// files, Emacs backups and auto-saves, and other hidden files are ignored.
    public static func classify(_ name: String) -> FileClassification {
        if name.hasPrefix(".") {
            if name.hasSuffix(".icloud") {
                let inner = String(name.dropFirst().dropLast(".icloud".count))
                if case .file = classify(inner) { return .placeholder(inner) }
            }
            return .ignored
        }
        if name.hasSuffix("~") || name.hasPrefix("#") { return .ignored }
        let conflict = name.contains(".sync-conflict-")
        if name.hasSuffix(".org") { return .file(conflict ? .conflict : .org) }
        if name.hasSuffix(".org_archive") { return .file(conflict ? .conflict : .archive) }
        return .ignored
    }

    /// Every org file under `root`, skipping hidden folders (`.git`, `.stfolder`, `.stversions`).
    public static func scan(_ root: URL) throws -> Discovery {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return Discovery()
        }
        var discovery = Discovery()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent
            if values.isDirectory == true {
                if name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            switch classify(name) {
            case .file(let kind):
                discovery.files.append(DiscoveredFile(
                    url: url.standardizedFileURL,
                    kind: kind,
                    size: values.fileSize ?? 0,
                    mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
                ))
            case .placeholder(let inner):
                discovery.placeholders.append(url.deletingLastPathComponent().appendingPathComponent(inner).standardizedFileURL)
            case .ignored:
                break
            }
        }
        discovery.files.sort { $0.url.path < $1.url.path }
        return discovery
    }
}

/// Which files feed the agenda: `.org` files (not archives or conflict copies) matching one of
/// the globs, relative to their root. No globs means every `.org` file.
public struct AgendaScope: Sendable, Equatable {
    public var globs: [String]

    public init(globs: [String] = []) {
        self.globs = globs
    }

    public func contains(relativePath: String, kind: FileKind) -> Bool {
        guard kind == .org else { return false }
        guard !globs.isEmpty else { return true }
        // Without FNM_PATHNAME, `*` also matches `/`, so `work/*` covers nested folders.
        return globs.contains { fnmatch($0, relativePath, 0) == 0 }
    }
}
```

- [x] **Step 4: Run to verify pass, then commit**

Run: `swift test --filter "ClassificationTests|ScanTests"`

```bash
git add Package.swift Sources/OrgWorkspace/Discovery.swift Tests/OrgWorkspaceTests/Folder.swift Tests/OrgWorkspaceTests/DiscoveryTests.swift
git commit -m "Add workspace discovery and agenda scope"
```

---

### Task 4: Reconciliation

**Files:**
- Create: `Sources/OrgWorkspace/Reconciler.swift`
- Test: `Tests/OrgWorkspaceTests/ReconcileTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `Reconciler(index:settings:)` with `reconcile(root:)` and `reconcile(root:paths:)`, `ReconcileReport`.

- [x] **Step 1: Write the failing tests**

```swift
import Foundation
import OrgIndex
import Testing
@testable import OrgWorkspace

struct ReconcileTests {
    @Test func indexesUpdatesMovesAndRemoves() throws {
        let folder = try Folder()
        let index = try IndexStore()
        let reconciler = Reconciler(index: index, settings: IndexSettings())
        let a = try folder.write("a.org", "* Alpha\n")
        try folder.write("b.org", "* Beta\n")

        var report = try reconciler.reconcile(root: folder.url)
        #expect(report.indexed.count == 2)
        #expect(try index.search("alpha").map(\.path) == [a.path])

        report = try reconciler.reconcile(root: folder.url)
        #expect(report.unchanged == 2 && report.indexed.isEmpty)

        try FileManager.default.moveItem(at: folder.url.appendingPathComponent("b.org"), to: folder.url.appendingPathComponent("c.org"))
        try folder.write("a.org", "* Gamma\n")
        report = try reconciler.reconcile(root: folder.url)
        #expect(report.moved.map { URL(fileURLWithPath: $0).lastPathComponent } == ["c.org"])
        #expect(report.indexed == [a.path])
        #expect(try index.search("gamma").count == 1)
        #expect(try index.search("beta").map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["c.org"])

        try FileManager.default.removeItem(at: a)
        report = try reconciler.reconcile(root: folder.url)
        #expect(report.removed == [a.path])
        #expect(try index.search("gamma").isEmpty)
    }

    @Test func touchedFileWithSameContentIsNotReparsed() throws {
        let folder = try Folder()
        let index = try IndexStore()
        let reconciler = Reconciler(index: index, settings: IndexSettings())
        let a = try folder.write("a.org", "* Alpha\n")
        _ = try reconciler.reconcile(root: folder.url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: a.path)
        #expect(try reconciler.reconcile(root: folder.url).touched == [a.path])
    }

    @Test func newSettingsVersionReindexes() throws {
        let folder = try Folder()
        let index = try IndexStore()
        try folder.write("a.org", "* Alpha\n")
        _ = try Reconciler(index: index, settings: IndexSettings(version: 1)).reconcile(root: folder.url)
        #expect(try Reconciler(index: index, settings: IndexSettings(version: 2)).reconcile(root: folder.url).indexed.count == 1)
    }

    @Test func conflictCopiesAreListedButNotSearchable() throws {
        let folder = try Folder()
        let index = try IndexStore()
        try folder.write("a.sync-conflict-1.org", "* Alpha\n")
        _ = try Reconciler(index: index, settings: IndexSettings()).reconcile(root: folder.url)
        #expect(try index.files().map(\.kind) == [.conflict])
        #expect(try index.search("alpha").isEmpty)
    }

    @Test func reconcilingChangedPaths() throws {
        let folder = try Folder()
        let index = try IndexStore()
        let reconciler = Reconciler(index: index, settings: IndexSettings())
        let a = try folder.write("a.org", "* Alpha\n")
        let b = try folder.write("b.org", "* Beta\n")
        _ = try reconciler.reconcile(root: folder.url)
        try folder.write("a.org", "* Delta\n")
        try FileManager.default.removeItem(at: b)
        let report = try reconciler.reconcile(root: folder.url, paths: [a, b])
        #expect(report.indexed == [a.path])
        #expect(report.removed == [b.path])
    }

    @Test func rootBookmarkResolves() throws {
        let folder = try Folder()
        let root = try WorkspaceRoot(url: folder.url)
        #expect(try root.resolve().url.resolvingSymlinksInPath() == folder.url.resolvingSymlinksInPath())
    }
}
```

- [x] **Step 2: Implement**

```swift
import Foundation
import OrgIndex

public struct ReconcileReport: Sendable, Equatable {
    public var indexed: [String] = []
    public var touched: [String] = []
    public var moved: [String] = []
    public var removed: [String] = []
    public var unchanged = 0
    /// iCloud files asked to download; they are indexed once they arrive.
    public var placeholders: [URL] = []
}

/// Brings the index in line with the files under a root. File events are only hints, so this
/// is what runs at launch, after dropped events, and for every batch of changed paths.
public struct Reconciler: Sendable {
    public let index: IndexStore
    public let settings: IndexSettings

    public init(index: IndexStore, settings: IndexSettings) {
        self.index = index
        self.settings = settings
    }

    /// Reconciles the whole root.
    public func reconcile(root: URL) throws -> ReconcileReport {
        let discovery = try WorkspaceScanner.scan(root)
        for placeholder in discovery.placeholders {
            try? FileManager.default.startDownloadingUbiquitousItem(at: placeholder)
        }
        var report = try reconcile(root: root, found: discovery.files, known: index.fileStates(root: root.path))
        report.placeholders = discovery.placeholders
        return report
    }

    /// Reconciles only `paths` under the root, for a batch of file events.
    public func reconcile(root: URL, paths: [URL]) throws -> ReconcileReport {
        let wanted = Set(paths.map(\.standardizedFileURL.path))
        let known = try index.fileStates(root: root.path).filter { wanted.contains($0.key) }
        var found: [DiscoveredFile] = []
        for url in paths.map(\.standardizedFileURL) {
            guard case .file(let kind) = WorkspaceScanner.classify(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory != true else { continue }
            found.append(DiscoveredFile(
                url: url, kind: kind, size: values.fileSize ?? 0,
                mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return try reconcile(root: root, found: found, known: known)
    }

    private func reconcile(root: URL, found: [DiscoveredFile], known: [String: FileState]) throws -> ReconcileReport {
        var report = ReconcileReport()
        var change = IndexChange()
        var candidates: [(file: DiscoveredFile, bytes: [UInt8], hash: String)] = []

        for file in found {
            let path = file.url.path
            if let state = known[path], state.size == file.size, state.mtime == file.mtime,
               state.settingsVersion == settings.version, state.kind == file.kind {
                report.unchanged += 1
                continue
            }
            guard let data = try? Data(contentsOf: file.url) else { continue }
            let bytes = [UInt8](data)
            let hash = FileRecord.hash(bytes)
            if let state = known[path], state.hash == hash, state.settingsVersion == settings.version, state.kind == file.kind {
                change.touches.append((path, file.mtime))
                report.touched.append(path)
            } else {
                candidates.append((file, bytes, hash))
            }
        }

        // A file that vanished and one that appeared with the same content is a rename.
        let foundPaths = Set(found.map(\.url.path))
        var missing = known.filter { !foundPaths.contains($0.key) }
        for candidate in candidates {
            let path = candidate.file.url.path
            if known[path] == nil,
               let (oldPath, _) = missing.first(where: {
                   $0.value.hash == candidate.hash && $0.value.settingsVersion == settings.version && $0.value.kind == candidate.file.kind
               }) {
                missing[oldPath] = nil
                change.moves.append((oldPath, path, candidate.file.mtime))
                report.moved.append(path)
            } else {
                change.records.append(FileRecord(
                    path: path, root: root.path, kind: candidate.file.kind,
                    bytes: candidate.bytes, mtime: candidate.file.mtime, settings: settings
                ))
                report.indexed.append(path)
            }
        }
        change.removals = missing.keys.sorted()
        report.removed = change.removals
        try index.apply(change)
        return report
    }
}
```

- [x] **Step 3: Run to verify pass, then commit**

Run: `swift test --filter ReconcileTests`

```bash
git add Sources/OrgWorkspace/Reconciler.swift Tests/OrgWorkspaceTests/ReconcileTests.swift
git commit -m "Add index reconciliation"
```

---

### Task 5: FSEvents watcher

**Files:**
- Create: `Sources/OrgWorkspace/FSEventsWatcher.swift`
- Test: `Tests/OrgWorkspaceTests/WatcherTests.swift`

**Interfaces:**
- Produces (macOS): `WatchEvent` (`.changed(URL)`, `.rescan(URL)`), `FSEventsWatcher(roots:latency:handler:)` with `start()`, `stop()`.

- [x] **Step 1: Write the failing test**

```swift
import Foundation
import OrgIndex
import Testing
@testable import OrgWorkspace

struct WatcherTests {
    @Test func reportsAWrittenFile() throws {
        let folder = try Folder()
        let received = Received()
        let watcher = FSEventsWatcher(roots: [folder.url.resolvingSymlinksInPath()], latency: 0.05) { received.add($0) }
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.2)
        try folder.write("a.org", "* a\n")
        #expect(received.wait(for: "a.org", timeout: 5))
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [WatchEvent] = []

    func add(_ batch: [WatchEvent]) {
        lock.withLock { events += batch }
    }

    func wait(for name: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let found = lock.withLock {
                events.contains { if case .changed(let url) = $0 { return url.lastPathComponent == name } else { return false } }
            }
            if found { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
```

- [x] **Step 2: Implement**

```swift
#if os(macOS)
import CoreServices
import Foundation

public enum WatchEvent: Sendable, Equatable {
    case changed(URL)
    /// Events were dropped or coalesced for this folder, or a root moved: rescan it.
    case rescan(URL)
}

/// FSEvents with file-level events. Delivers batches on a private queue.
public final class FSEventsWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let handler: @Sendable ([WatchEvent]) -> Void
    private let queue = DispatchQueue(label: "orgstar.fsevents")
    private var stream: FSEventStreamRef?

    public init(roots: [URL], latency: CFTimeInterval = 0.3, handler: @escaping @Sendable ([WatchEvent]) -> Void) {
        paths = roots.map(\.path)
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.deliver(paths: paths, flags: Array(UnsafeBufferPointer(start: eventFlags, count: count)))
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func deliver(paths eventPaths: [String], flags: [FSEventStreamEventFlags]) {
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
        )
        var events: [WatchEvent] = []
        for (path, flag) in zip(eventPaths, flags) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if flag & rescanFlags != 0 {
                let root = paths.first { path.hasPrefix($0) } ?? path
                events.append(.rescan(URL(fileURLWithPath: root).standardizedFileURL))
            } else {
                events.append(.changed(url))
            }
        }
        if !events.isEmpty { handler(events) }
    }
}
#endif
```

- [x] **Step 3: Run everything, the iOS build and the gates** (gates run on an M-series Mac, recorded in docs/design.md; the M1 Air run is owed)

Run: `swift test`, then `xcodebuild -scheme OrgWorkspace -destination 'generic/platform=iOS' build`.
Gates: reconcile a folder of 10,000 org files into an empty index (under 30 s), then again with no changes (under 2 s), in a release build on the reference machine.

- [x] **Step 4: Commit**

```bash
git add Sources/OrgWorkspace/FSEventsWatcher.swift Tests/OrgWorkspaceTests/WatcherTests.swift
git commit -m "Add FSEvents watcher"
```
