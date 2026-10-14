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
public struct IndexedHeading: Sendable, Hashable {
    public let location: HeadingLocation
    public let level: Int
    /// Titles from the top-level ancestor down to the heading itself.
    public let outlinePath: [String]
}

public struct HeadingLocation: Sendable, Hashable {
    public let path: String
    /// `fileOrdinal` for the file itself, before its first heading.
    public let ordinal: Int
    public let title: String
    public let start: Int
    public let contentHash: String
    /// The text around the match, for search results whose match is in the text.
    public internal(set) var snippet: Snippet?

    public init(path: String, ordinal: Int, title: String, start: Int, contentHash: String) {
        self.path = path
        self.ordinal = ordinal
        self.title = title
        self.start = start
        self.contentHash = contentHash
    }

    public static let fileOrdinal = -1

    /// The file before its first heading, titled by its name.
    public static func file(_ path: String, contentHash: String) -> HeadingLocation {
        HeadingLocation(path: path, ordinal: fileOrdinal, title: (path as NSString).lastPathComponent, start: 0, contentHash: contentHash)
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
        migrator.registerMigration("v2") { db in
            // Links before a file's first heading; files are read again to fill it.
            try db.execute(sql: """
                CREATE TABLE file_links (
                    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                    type TEXT NOT NULL,
                    target TEXT NOT NULL
                );
                CREATE INDEX file_links_file ON file_links(file_id);
                UPDATE files SET settings_version = -1;
                """)
        }
        migrator.registerMigration("v3") { db in
            // File-level IDs and titles, for org-roam file nodes; files are read again to fill them.
            try db.execute(sql: """
                ALTER TABLE files ADD COLUMN org_id TEXT;
                ALTER TABLE files ADD COLUMN title TEXT;
                CREATE INDEX files_org_id ON files(org_id);
                UPDATE files SET settings_version = -1;
                """)
        }
        migrator.registerMigration("v4") { db in
            // Text before a file's first heading, searched as the file; files are read again to fill it.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE files_fts USING fts5(body, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TRIGGER files_fts_delete AFTER DELETE ON files BEGIN
                    DELETE FROM files_fts WHERE rowid = old.id;
                END;
                UPDATE files SET settings_version = -1;
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
                INSERT INTO files (path, root, kind, size, mtime, hash, settings_version, parsed_at, org_id, title)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [record.path, record.root, record.kind.rawValue, record.size, record.mtime, record.hash,
                        record.settingsVersion, Date().timeIntervalSince1970, record.fileID, record.title]
        )
        let fileID = db.lastInsertedRowID
        if !record.preamble.allSatisfy(\.isWhitespace) {
            try db.execute(sql: "INSERT INTO files_fts (rowid, body) VALUES (?, ?)", arguments: [fileID, record.preamble])
        }
        for link in record.links {
            try db.execute(sql: "INSERT INTO file_links VALUES (?, ?, ?)", arguments: [fileID, link.type, link.target])
        }
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

    /// Headings whose title or body contain every word of `query` as a word prefix, and files
    /// whose text before the first heading does, best first, each with a snippet of the text
    /// when the match is there.
    public func search(_ query: String, overlay: [String: FileRecord] = [:], limit: Int = 50) throws -> [HeadingLocation] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " ")
        let prefixes = terms.flatMap(Self.words)
        func withSnippet(_ location: HeadingLocation, _ body: String) -> HeadingLocation {
            var location = location
            location.snippet = Snippet(text: body, prefixes: prefixes)
            return location
        }
        let indexed = try database.read { db in
            let headings = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.path, f.hash, h.ordinal, h.title, h.start_offset, headings_fts.body, bm25(headings_fts) AS rank
                    FROM headings_fts
                    JOIN headings h ON h.id = headings_fts.rowid
                    JOIN files f ON f.id = h.file_id
                    WHERE headings_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [match, limit + overlay.count * 10]
            ).map { (location: withSnippet(location($0), $0["body"]), rank: $0["rank"] as Double) }
            let files = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.path, f.hash, f.title, files_fts.body, bm25(files_fts) AS rank
                    FROM files_fts
                    JOIN files f ON f.id = files_fts.rowid
                    WHERE files_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                arguments: [match, limit + overlay.count]
            ).map { (location: withSnippet(fileLocation($0["path"], title: $0["title"], hash: $0["hash"]), $0["body"]), rank: $0["rank"] as Double) }
            return (headings + files).sorted { $0.rank < $1.rank }.map(\.location)
        }
        // Unsaved buffers get the same word-prefix matching as the full-text index.
        func matches(_ text: String) -> Bool {
            let words = Self.words(text)
            return prefixes.allSatisfy { prefix in words.contains { $0.hasPrefix(prefix) } }
        }
        let live = overlay.values.sorted { $0.path < $1.path }.flatMap { record in
            let file = matches(record.preamble) ? [withSnippet(fileLocation(record.path, title: record.title, hash: record.hash), record.preamble)] : []
            return file + record.headings.filter { matches($0.title + "\n" + $0.body) }.map { withSnippet(location(record, $0), $0.body) }
        }
        return Array((live + indexed.filter { overlay[$0.path] == nil }).prefix(limit))
    }

    /// The file before its first heading, titled by its `#+TITLE` or else its name.
    private func fileLocation(_ path: String, title: String?, hash: String) -> HeadingLocation {
        let file = HeadingLocation.file(path, contentHash: hash)
        guard let title, !title.isEmpty else { return file }
        return HeadingLocation(path: path, ordinal: file.ordinal, title: title, start: 0, contentHash: hash)
    }

    /// Headings down to `maxLevel` in org files (not archives or conflict copies), with their
    /// levels and outline paths, in file order: refile targets.
    public func outline(maxLevel: Int) throws -> [IndexedHeading] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.path, f.hash, h.ordinal, h.title, h.start_offset, h.level, h.outline_path
                    FROM headings h JOIN files f ON f.id = h.file_id
                    WHERE h.level <= ? AND f.kind = 'org' ORDER BY f.path, h.ordinal
                    """,
                arguments: [maxLevel]
            ).map { row in
                IndexedHeading(
                    location: location(row), level: row["level"],
                    outlinePath: (row["outline_path"] as String).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
                )
            }
        }
    }

    /// Headings with `:ID: id`. More than one means the ID is duplicated.
    /// Every tag a heading has, most used first.
    public func tags() throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT tag FROM tags WHERE inherited = 0 GROUP BY tag ORDER BY count(*) DESC, tag")
        }
    }

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
        let files = try database.read { db in
            try Row.fetchAll(db, sql: "SELECT path, hash FROM files WHERE org_id = ? ORDER BY path", arguments: [id])
                .map { HeadingLocation.file($0["path"], contentHash: $0["hash"]) }
        }
        let live = overlay.values.sorted { $0.path < $1.path }.flatMap { record in
            (record.fileID == id ? [HeadingLocation.file(record.path, contentHash: record.hash)] : [])
                + record.headings.filter { $0.orgID == id }.map { location(record, $0) }
        }
        return (files + indexed).filter { overlay[$0.path] == nil } + live
    }

    /// A heading or file with an ID: an org-roam node.
    public struct Node: Sendable, Hashable {
        public let id: String
        public let title: String
        public let location: HeadingLocation
    }

    /// Every heading and file with an ID, files first, unsaved buffers' in place of their
    /// files'. A file's title is its `#+TITLE`, else its name without `.org`.
    public func nodes(overlay: [String: FileRecord] = [:]) throws -> [Node] {
        func fileTitle(_ path: String, _ title: String?) -> String { title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        let indexed = try database.read { db in
            let files = try Row.fetchAll(db, sql: "SELECT path, hash, org_id, title FROM files WHERE org_id IS NOT NULL AND kind = 'org' ORDER BY path").map { row in
                Node(id: row["org_id"], title: fileTitle(row["path"], row["title"]), location: .file(row["path"], contentHash: row["hash"]))
            }
            let headings = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.path, f.hash, h.ordinal, h.title, h.start_offset, h.org_id
                    FROM headings h JOIN files f ON f.id = h.file_id
                    WHERE h.org_id IS NOT NULL AND f.kind = 'org' ORDER BY f.path, h.ordinal
                    """
            ).map { Node(id: $0["org_id"], title: $0["title"], location: location($0)) }
            return files + headings
        }
        let live = overlay.values.sorted { $0.path < $1.path }.flatMap { record in
            (record.fileID.map { [Node(id: $0, title: fileTitle(record.path, record.title), location: .file(record.path, contentHash: record.hash))] } ?? [])
                + record.headings.compactMap { heading in heading.orgID.map { Node(id: $0, title: heading.title, location: location(record, heading)) } }
        }
        return indexed.filter { overlay[$0.location.path] == nil } + live
    }

    /// Every link and the heading it's in, or the file for links before its first heading,
    /// unsaved buffers' in place of their files'.
    public func links(overlay: [String: FileRecord] = [:]) throws -> [(source: HeadingLocation, target: String)] {
        let indexed = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT f.path, f.hash, -1 AS ordinal, '' AS title, 0 AS start_offset, l.target
                    FROM file_links l JOIN files f ON f.id = l.file_id WHERE f.kind = 'org'
                    UNION ALL
                    SELECT f.path, f.hash, h.ordinal, h.title, h.start_offset, l.target
                    FROM links l JOIN headings h ON h.id = l.heading_id JOIN files f ON f.id = h.file_id
                    WHERE f.kind = 'org' ORDER BY 1, 3
                    """
            ).map { row in
                let location = location(row)
                return (source: location.ordinal == HeadingLocation.fileOrdinal ? .file(location.path, contentHash: location.contentHash) : location,
                        target: row["target"] as String)
            }
        }
        let live = overlay.values.sorted { $0.path < $1.path }.flatMap { record in
            record.links.map { (source: HeadingLocation.file(record.path, contentHash: record.hash), target: $0.target) }
                + record.headings.flatMap { heading in heading.links.map { (source: location(record, heading), target: $0.target) } }
        }
        return indexed.filter { overlay[$0.source.path] == nil } + live
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
