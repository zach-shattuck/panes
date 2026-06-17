import Foundation
import SQLite3
import os

/// Raw SQLite3 persistence — no ORM dependency for one table. Opted out of
/// MainActor isolation (`nonisolated`) so the handle can be closed from
/// deinit; all call sites happen to be main-thread anyway and SQLite is in
/// serialized mode by default on Apple platforms.
nonisolated final class ClipboardStore {
    private var db: OpaquePointer?
    private let log = Logger.panes("clipboard-store")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Unpinned rows beyond this are pruned oldest-first on every insert.
    private let capacity: Int
    /// Unpinned entries older than this are dropped (privacy hygiene — clipboard
    /// contents shouldn't linger on disk indefinitely). `0` means keep forever.
    /// Mutable so the expiry setting can change it at runtime.
    var maxAge: TimeInterval

    init?(directory: URL, capacity: Int = 500, maxAge: TimeInterval = 30 * 24 * 60 * 60) {
        self.capacity = capacity
        self.maxAge = maxAge
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("cannot create store directory: \(error)")
            return nil
        }
        // Keep the directory owner-only so another local user can't read the
        // clipboard database out of Application Support.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let path = directory.appendingPathComponent("clipboard.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            log.error("sqlite open failed")
            return nil
        }
        // Lock the database file down to the owner (it's created on open).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let schema = """
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL,
            text TEXT,
            data BLOB,
            source_bundle TEXT,
            pinned INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_items_created ON items(created_at DESC);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            log.error("schema creation failed")
            return nil
        }
        // Add `pinned` to databases created before pinning existed. Errors
        // harmlessly (the column already exists), so the result is ignored.
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        // Clear anything already past its age on launch, even with no new copy.
        prune()
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    func insert(
        kind: ClipboardItem.Kind,
        text: String?,
        data: Data?,
        sourceBundleID: String?
    ) -> ClipboardItem? {
        let sql = "INSERT INTO items (created_at, kind, text, data, source_bundle) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let now = Date()
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, kind.rawValue, -1, Self.transient)
        if let text {
            sqlite3_bind_text(statement, 3, text, -1, Self.transient)
        }
        if let data {
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(bytes.count), Self.transient)
            }
        }
        if let sourceBundleID {
            sqlite3_bind_text(statement, 5, sourceBundleID, -1, Self.transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        prune()
        return ClipboardItem(
            id: sqlite3_last_insert_rowid(db),
            createdAt: now,
            kind: kind,
            text: text,
            data: data,
            sourceBundleID: sourceBundleID,
            pinned: false
        )
    }

    func recent(limit: Int = 100, matching query: String? = nil) -> [ClipboardItem] {
        var sql = "SELECT id, created_at, kind, text, data, source_bundle, pinned FROM items"
        if query?.isEmpty == false {
            sql += " WHERE text LIKE ?"
        }
        // Pinned first, then newest. Keeps favorites at the top of the list.
        sql += " ORDER BY pinned DESC, created_at DESC LIMIT \(limit)"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let query, !query.isEmpty {
            sqlite3_bind_text(statement, 1, "%\(query)%", -1, Self.transient)
        }

        var items: [ClipboardItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kindRaw = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "text"
            var data: Data?
            if let blob = sqlite3_column_blob(statement, 4) {
                data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 4)))
            }
            items.append(ClipboardItem(
                id: sqlite3_column_int64(statement, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: ClipboardItem.Kind(rawValue: kindRaw) ?? .text,
                text: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                data: data,
                sourceBundleID: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                pinned: sqlite3_column_int64(statement, 6) != 0
            ))
        }
        return items
    }

    func setPinned(_ id: Int64, _ pinned: Bool) {
        let sql = "UPDATE items SET pinned = ? WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, pinned ? 1 : 0)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    func deleteAll() {
        // Keep pinned favorites even on a "clear history".
        sqlite3_exec(db, "DELETE FROM items WHERE pinned = 0", nil, nil, nil)
    }

    /// Run a prune now (e.g. after the expiry setting shortens).
    func pruneNow() { prune() }

    private func prune() {
        // Never drop pinned items. Among the rest: remove anything past the age
        // limit (if one is set), then trim back to capacity. The interpolated
        // values are all numeric, so this is injection-safe.
        var clauses = ["id NOT IN (SELECT id FROM items WHERE pinned = 0 ORDER BY created_at DESC LIMIT \(capacity))"]
        if maxAge > 0 {
            let cutoff = Date().timeIntervalSince1970 - maxAge
            clauses.insert("created_at < \(cutoff)", at: 0)
        }
        let sql = "DELETE FROM items WHERE pinned = 0 AND (\(clauses.joined(separator: " OR ")));"
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
