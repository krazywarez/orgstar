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
public struct HeadingLocation: Sendable, Hashable {
    public let path: String
    public let ordinal: Int
    public let title: String
    public let start: Int
    public let contentHash: String

    public init(path: String, ordinal: Int, title: String, start: Int, contentHash: String) {
        self.path = path
        self.ordinal = ordinal
        self.title = title
        self.start = start
        self.contentHash = contentHash
    }
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
