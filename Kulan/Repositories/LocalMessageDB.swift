import Foundation
import SQLite3

/// ⛔ THE PHONE'S OWN MESSAGE DATABASE (owner 2026-11-12: private chats live on the phone, like the
/// big messengers; Documents/fariin-plans/2026-11-12-device-storage-plan.md, phase 1). Android has
/// the same file name, tables and columns (framework SQLite there, the system sqlite3 here: no new
/// package on either side).
///
/// Phase 1: every message the app decrypts is written here, and a chat reads its older pages from
/// here before asking the server. The server still keeps everything until phase 2, so this database
/// is additive: a fault here must never cost a message on screen (every call fails quietly).
///
/// - `fariin-local-<uid>.db` in Application Support, one per account.
/// - Never in a system backup (`isExcludedFromBackup`); history leaves the phone only in our own
///   end-to-end encrypted backup (phase 3).
/// - Bodies are the decrypted message (this app's own JSON of `Message`), protected by iOS file
///   protection (available after first unlock, so a notification can still be filed).
/// - Disappearing messages are purged here at the moment they vanish from the chat; a deleted
///   message keeps its row with an empty body; an opened view-once loses its body.
final class LocalMessageDB {
    static let shared = LocalMessageDB()
    private init() {}

    static let schemaVersion = 1
    /// All database work, in order, off the main thread.
    private let queue = DispatchQueue(label: "fariin.localdb", qos: .utility)
    private var db: OpaquePointer?
    private var openUid: String?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d
    }()

    // MARK: - Writing

    /// Files these messages (new or changed). Local-only rows (notices, sends still in flight) are
    /// left out: only what the server has is history.
    func upsert(cid: String, uid: String, _ messages: [Message]) {
        let rows = messages.filter { $0.sendState == nil && $0.localNoticeSymbol == nil && !$0.id.hasPrefix("local-") }
        guard !rows.isEmpty, !uid.isEmpty else { return }
        queue.async {
            guard let db = self.handle(uid) else { return }
            let now = Self.ms(Date())
            let sql = """
                INSERT INTO messages (cid, id, created_at, sender, type, deleted, edited_at, expires_at, body, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cid, id) DO UPDATE SET created_at = excluded.created_at, sender = excluded.sender,
                  type = excluded.type, deleted = excluded.deleted, edited_at = excluded.edited_at,
                  expires_at = excluded.expires_at, body = excluded.body, updated_at = excluded.updated_at
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for m in rows {
                // Delete-for-everyone keeps the row, not the words; an opened view-once loses its photo.
                let body: String
                if m.deleted || (m.viewOnce && m.consumed) {
                    body = "{}"
                } else if let data = try? Self.encoder.encode(m), let s = String(data: data, encoding: .utf8) {
                    body = s
                } else { continue }
                sqlite3_reset(stmt)
                Self.bind(stmt, 1, cid)
                Self.bind(stmt, 2, m.id)
                sqlite3_bind_int64(stmt, 3, Self.ms(m.createdAt))
                Self.bind(stmt, 4, m.authorId)
                Self.bind(stmt, 5, m.type ?? "text")
                sqlite3_bind_int64(stmt, 6, m.deleted ? 1 : 0)
                if m.edited { sqlite3_bind_int64(stmt, 7, now) } else { sqlite3_bind_null(stmt, 7) }
                if let e = m.expiresAt { sqlite3_bind_int64(stmt, 8, Self.ms(e)) } else { sqlite3_bind_null(stmt, 8) }
                Self.bind(stmt, 9, body)
                sqlite3_bind_int64(stmt, 10, now)
                sqlite3_step(stmt)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    /// Disappearing messages whose time is up leave the phone (on open and on the chat's timer).
    func purgeExpired(uid: String) {
        queue.async {
            guard let db = self.handle(uid) else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Self.ms(Date()))
            sqlite3_step(stmt)
        }
    }

    /// One chat's messages leave the phone (Clear History / Delete Chat for me).
    func removeChat(cid: String, uid: String) {
        queue.async {
            guard let db = self.handle(uid) else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM messages WHERE cid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            Self.bind(stmt, 1, cid)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Reading

    /// Up to `limit` messages of `cid` older than `before` (newest first from the database, handed
    /// back oldest first). Rows whose body no longer opens (deleted, burned view-once) are skipped:
    /// the server's own copy still draws those in phase 1. `done` runs on the main thread.
    func older(cid: String, uid: String, before: Date, limit: Int, done: @escaping ([Message]) -> Void) {
        queue.async {
            var out: [Message] = []
            if let db = self.handle(uid) {
                var stmt: OpaquePointer?
                let sql = "SELECT body FROM messages WHERE cid = ? AND created_at < ? AND deleted = 0 ORDER BY created_at DESC LIMIT ?"
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    Self.bind(stmt, 1, cid)
                    sqlite3_bind_int64(stmt, 2, Self.ms(before))
                    sqlite3_bind_int64(stmt, 3, Int64(limit))
                    let now = Date()
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let c = sqlite3_column_text(stmt, 0) else { continue }
                        let s = String(cString: c)
                        guard s != "{}", let data = s.data(using: .utf8),
                              let m = try? Self.decoder.decode(Message.self, from: data) else { continue }
                        if let e = m.expiresAt, e <= now { continue }
                        out.append(m)
                    }
                    sqlite3_finalize(stmt)
                }
            }
            let page = Array(out.reversed())
            DispatchQueue.main.async { done(page) }
        }
    }

    // MARK: - The file

    /// Account deletion: this account's history goes with it.
    func wipe(uid: String) {
        queue.async {
            if self.openUid == uid { self.close() }
            if let url = Self.fileURL(uid) {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
                }
            }
        }
    }

    /// The open database for `uid` (on `queue` only). Another account's file is closed first.
    private func handle(_ uid: String) -> OpaquePointer? {
        if openUid == uid, let db { return db }
        close()
        guard let url = Self.fileURL(uid) else { return nil }
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &h, flags, nil) == SQLITE_OK, let h else {
            if let h { sqlite3_close(h) }
            return nil
        }
        sqlite3_exec(h, "PRAGMA journal_mode = WAL", nil, nil, nil)
        sqlite3_exec(h, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        let schema = """
            CREATE TABLE IF NOT EXISTS messages (
              cid TEXT NOT NULL, id TEXT NOT NULL, created_at INTEGER NOT NULL, sender TEXT, type TEXT,
              deleted INTEGER NOT NULL DEFAULT 0, edited_at INTEGER, expires_at INTEGER, body TEXT,
              updated_at INTEGER, PRIMARY KEY (cid, id));
            CREATE INDEX IF NOT EXISTS messages_cid_created ON messages (cid, created_at);
            CREATE INDEX IF NOT EXISTS messages_expires ON messages (expires_at);
            CREATE TABLE IF NOT EXISTS chats (
              cid TEXT PRIMARY KEY, last_id TEXT, last_at INTEGER, unread INTEGER, delivered_up_to INTEGER,
              synced_up_to INTEGER, oldest_pulled INTEGER, body TEXT);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', '\(Self.schemaVersion)');
            """
        guard sqlite3_exec(h, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(h); return nil }
        // Never in an iCloud / iTunes backup (agreed with Android): only our own backup carries history.
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        db = h
        openUid = uid
        return h
    }

    private func close() {
        if let db { sqlite3_close(db) }
        db = nil
        openUid = nil
    }

    private static func fileURL(_ uid: String) -> URL? {
        guard !uid.isEmpty, uid.allSatisfy({ $0.isLetter || $0.isNumber }),
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("LocalDB", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var d = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? d.setResourceValues(values)
        }
        return dir.appendingPathComponent("fariin-local-\(uid).db")
    }

    private static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    /// SQLITE_TRANSIENT: SQLite copies the text before the Swift string goes away.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(stmt, i, s, -1, transient)
    }
}

// MARK: - Raw rows for the backup (phase 3)

/// The backup archive (BackupArchive, format v1 agreed with Android) carries the database's rows as
/// they are, column for column, not through `Message`: a row Android wrote and a row iOS wrote travel
/// the same way. Values are `String`, `NSNumber` (INTEGER / REAL) or `NSNull`, ready for
/// JSONSerialization. Every function here waits for the database queue, so never call one ON it
/// (they are for the backup's own background task).
extension LocalMessageDB {
    typealias RawRow = [String: Any]

    static let messageColumns = ["cid", "id", "created_at", "sender", "type", "deleted", "edited_at",
                                 "expires_at", "body", "updated_at"]
    static let chatColumns = ["cid", "last_id", "last_at", "unread", "delivered_up_to", "synced_up_to",
                              "oldest_pulled", "body"]

    /// Every message row of `uid`, oldest first (created_at, then cid, id), handed to `each` one page
    /// at a time so memory stays at one page however big the history is. The queue is let go between
    /// pages, so the chats keep filing while a backup reads. `each` runs on the caller's thread.
    func allRows(uid: String, pageSize: Int = 2000, _ each: ([RawRow]) throws -> Void) rethrows {
        let cols = Self.messageColumns.joined(separator: ", ")
        let limit = Int64(max(1, pageSize))
        var after: (at: Int64, cid: String, id: String)?
        while true {
            let page: [RawRow] = queue.sync {
                guard let db = self.handle(uid) else { return [] }
                let sql = after == nil
                    ? "SELECT \(cols) FROM messages ORDER BY created_at, cid, id LIMIT ?1"
                    : "SELECT \(cols) FROM messages WHERE created_at > ?2 OR (created_at = ?2 AND (cid > ?3 OR (cid = ?3 AND id > ?4))) ORDER BY created_at, cid, id LIMIT ?1"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, limit)
                if let a = after {
                    sqlite3_bind_int64(stmt, 2, a.at)
                    Self.bind(stmt, 3, a.cid)
                    Self.bind(stmt, 4, a.id)
                }
                return Self.readRows(stmt, Self.messageColumns)
            }
            guard let last = page.last,
                  let at = (last["created_at"] as? NSNumber)?.int64Value,
                  let cid = last["cid"] as? String, let id = last["id"] as? String else { return }
            try each(page)
            if Int64(page.count) < limit { return }
            after = (at, cid, id)
        }
    }

    /// Every chats row of `uid` (one per chat, so small).
    func allChatRows(uid: String) -> [RawRow] {
        let cols = Self.chatColumns.joined(separator: ", ")
        return queue.sync {
            guard let db = self.handle(uid) else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT \(cols) FROM chats ORDER BY cid", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            return Self.readRows(stmt, Self.chatColumns)
        }
    }

    /// Restore: files backup rows as they are (INSERT OR REPLACE). Rows without cid / id /
    /// created_at are skipped. Returns how many were written.
    @discardableResult
    func insertRows(uid: String, rows: [RawRow]) -> Int {
        insertRaw(uid: uid, table: "messages", columns: Self.messageColumns,
                  required: ["cid": .text, "id": .text, "created_at": .integer],
                  defaults: ["deleted": NSNumber(value: 0)], rows: rows)
    }

    /// Restore: the chats rows (INSERT OR REPLACE). Rows without cid are skipped.
    @discardableResult
    func insertChatRows(uid: String, rows: [RawRow]) -> Int {
        insertRaw(uid: uid, table: "chats", columns: Self.chatColumns,
                  required: ["cid": .text], defaults: [:], rows: rows)
    }

    private enum RawKind { case text, integer }

    private func insertRaw(uid: String, table: String, columns: [String], required: [String: RawKind],
                           defaults: [String: Any], rows: [RawRow]) -> Int {
        guard !rows.isEmpty, !uid.isEmpty else { return 0 }
        let sql = "INSERT OR REPLACE INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))"
        return queue.sync {
            guard let db = self.handle(uid) else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            var written = 0
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for row in rows {
                let ok = required.allSatisfy { key, kind in
                    switch kind {
                    case .text: return (row[key] as? String).map { !$0.isEmpty } ?? false
                    case .integer: return row[key] is NSNumber
                    }
                }
                guard ok else { continue }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                for (i, col) in columns.enumerated() {
                    var v = row[col]
                    if v == nil || v is NSNull { v = defaults[col] }
                    Self.bindRaw(stmt, Int32(i + 1), v)
                }
                if sqlite3_step(stmt) == SQLITE_DONE { written += 1 }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            return written
        }
    }

    private static func readRows(_ stmt: OpaquePointer?, _ columns: [String]) -> [RawRow] {
        var out: [RawRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row = RawRow(minimumCapacity: columns.count)
            for (i, col) in columns.enumerated() {
                let c = Int32(i)
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER:
                    row[col] = NSNumber(value: sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT:
                    row[col] = NSNumber(value: sqlite3_column_double(stmt, c))
                case SQLITE_TEXT:
                    if let t = sqlite3_column_text(stmt, c) { row[col] = String(cString: t) } else { row[col] = NSNull() }
                default:
                    row[col] = NSNull()
                }
            }
            out.append(row)
        }
        return out
    }

    private static func bindRaw(_ stmt: OpaquePointer?, _ i: Int32, _ value: Any?) {
        guard let value, !(value is NSNull) else { sqlite3_bind_null(stmt, i); return }
        if let s = value as? String {
            bind(stmt, i, s)
        } else if let n = value as? NSNumber {
            if CFNumberIsFloatType(n as CFNumber) {
                sqlite3_bind_double(stmt, i, n.doubleValue)
            } else {
                sqlite3_bind_int64(stmt, i, n.int64Value)
            }
        } else {
            sqlite3_bind_null(stmt, i)
        }
    }
}
