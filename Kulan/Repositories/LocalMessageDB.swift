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
            let page = self.page(cid: cid, uid: uid, before: before, limit: limit)
            DispatchQueue.main.async { done(page) }
        }
    }

    /// ⛔ The newest `limit` messages of `cid` (owner 2026-11-12: a chat opens from the phone first,
    /// then the live listener takes over). Same rules as `older`; `done` runs on the main thread.
    func newest(cid: String, uid: String, limit: Int, done: @escaping ([Message]) -> Void) {
        queue.async {
            let page = self.page(cid: cid, uid: uid, before: nil, limit: limit)
            DispatchQueue.main.async { done(page) }
        }
    }

    /// One page of `cid`, oldest first; `before` nil = the newest rows (on `queue` only).
    private func page(cid: String, uid: String, before: Date?, limit: Int) -> [Message] {
        var out: [Message] = []
        guard let db = handle(uid) else { return out }
        var stmt: OpaquePointer?
        let sql = before == nil
            ? "SELECT body FROM messages WHERE cid = ? AND deleted = 0 ORDER BY created_at DESC LIMIT ?"
            : "SELECT body FROM messages WHERE cid = ? AND created_at < ? AND deleted = 0 ORDER BY created_at DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, cid)
        if let before {
            sqlite3_bind_int64(stmt, 2, Self.ms(before))
            sqlite3_bind_int64(stmt, 3, Int64(limit))
        } else {
            sqlite3_bind_int64(stmt, 2, Int64(limit))
        }
        let now = Date()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let s = String(cString: c)
            guard s != "{}", let data = s.data(using: .utf8),
                  let m = try? Self.decoder.decode(Message.self, from: data) else { continue }
            if let e = m.expiresAt, e <= now { continue }
            out.append(m)
        }
        return Array(out.reversed())
    }

    // MARK: - The file

    /// Account deletion, or Log Out with "Delete messages from this phone": this account's history goes.
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
