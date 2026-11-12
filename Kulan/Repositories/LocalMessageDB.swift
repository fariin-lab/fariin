import Foundation
import SQLite3
import UIKit

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
    private init() {
        // ⛔ NO LOCK WHILE SUSPENDED. The file sits in the shared App Group container, and iOS kills an
        // app that holds a file lock there when it suspends (0xDEAD10CC). Closed on every trip to the
        // background (writes queued before it finish first, under a background task); the next call
        // reopens it. `queue: nil`: runs on the posting thread, nothing waits on the main run loop.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.closeForBackground()
        }
    }

    private func closeForBackground() {
        var task: UIBackgroundTaskIdentifier = .invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "fariin.localdb.close") {
            UIApplication.shared.endBackgroundTask(task)
        }
        queue.async {
            self.close()
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(task) }
        }
    }

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
            // D5 (owner 2026-11-12): the chat list's row for this chat follows what was just filed.
            self.refreshSummary(db, cid: cid, uid: uid)
            Self.announceSummaries()
        }
    }

    /// Runs `f` on the main thread once every write queued before it has committed. The delivery
    /// cursor goes out only after the messages it vouches for are really on this phone (as Android).
    func afterWrites(_ f: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: f) }
    }

    /// Disappearing messages whose time is up leave the phone (on open and on the chat's timer).
    func purgeExpired(uid: String) {
        queue.async {
            guard let db = self.handle(uid) else { return }
            let now = Self.ms(Date())
            // D5 (owner 2026-11-12): the chats losing a message get their list row worked out again.
            let touched = self.cids(db, "SELECT DISTINCT cid FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?", now)
            guard !touched.isEmpty else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM messages WHERE expires_at IS NOT NULL AND expires_at <= ?",
                                     -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, now)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            for cid in touched { self.refreshSummary(db, cid: cid, uid: uid) }
            Self.announceSummaries()
        }
    }

    /// One chat's messages leave the phone (Clear History / Delete Chat for me).
    func removeChat(cid: String, uid: String) {
        queue.async {
            guard let db = self.handle(uid) else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM messages WHERE cid = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            Self.bind(stmt, 1, cid)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            // D5 (owner 2026-11-12): nothing left, so no local preview; the read mark stays.
            self.refreshSummary(db, cid: cid, uid: uid)
            Self.announceSummaries()
        }
    }

    /// ⛔ INBOX SYNC MARK (owner 2026-11-12, plan phase 2): `chats.synced_up_to` = the server time (ms)
    /// up to which `InboxSync` has pulled every message of `cid` to this phone. Only that column is
    /// written (a new chats row gets nothing else), and it never moves backwards. 0 is allowed (owner
    /// 2026-11-12): HistoryPull marks a chat with no messages at all as "everything up to 0 is here",
    /// and the forward-only WHERE below still keeps any real mark from being lowered to it.
    func setSyncedUpTo(cid: String, uid: String, ms: Int64) {
        guard !cid.isEmpty, !uid.isEmpty, ms >= 0 else { return }
        queue.async {
            guard let db = self.handle(uid) else { return }
            let sql = """
                INSERT INTO chats (cid, synced_up_to) VALUES (?, ?)
                ON CONFLICT(cid) DO UPDATE SET synced_up_to = excluded.synced_up_to
                WHERE chats.synced_up_to IS NULL OR chats.synced_up_to < excluded.synced_up_to
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            Self.bind(stmt, 1, cid)
            sqlite3_bind_int64(stmt, 2, ms)
            sqlite3_step(stmt)
        }
    }

    /// ⛔ One `meta` row (owner 2026-11-12: HistoryPull keeps its per-chat progress here so a pull
    /// resumes after a kill). nil value deletes the row. Queued like every write, so it lands after
    /// the rows filed before it.
    func setMeta(uid: String, key: String, _ value: String?) {
        guard !uid.isEmpty, !key.isEmpty else { return }
        queue.async {
            guard let db = self.handle(uid) else { return }
            let sql = value == nil
                ? "DELETE FROM meta WHERE key = ?"
                : "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            Self.bind(stmt, 1, key)
            if let value { Self.bind(stmt, 2, value) }
            sqlite3_step(stmt)
        }
    }

    // MARK: - Reading

    /// `chats.synced_up_to` of `cid` (nil = never pulled by InboxSync). `done` runs on the main thread.
    func syncedUpTo(cid: String, uid: String, done: @escaping (Int64?) -> Void) {
        queue.async {
            let value = self.syncedMarks(uid: uid, cid: cid)[cid]
            DispatchQueue.main.async { done(value) }
        }
    }

    /// Every chat's `synced_up_to` in one read (InboxSync picks its chats from this). Main thread.
    func syncedUpTo(uid: String, done: @escaping ([String: Int64]) -> Void) {
        queue.async {
            let marks = self.syncedMarks(uid: uid, cid: nil)
            DispatchQueue.main.async { done(marks) }
        }
    }

    /// Every `meta` row whose key starts with `prefix`, key -> value, in one read. Main thread.
    func meta(uid: String, prefix: String, done: @escaping ([String: String]) -> Void) {
        queue.async {
            var out: [String: String] = [:]
            if let db = self.handle(uid) {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT key, value FROM meta WHERE substr(key, 1, ?) = ?",
                                      -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, Int64(prefix.unicodeScalars.count))
                    Self.bind(stmt, 2, prefix)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) else { continue }
                        out[String(cString: k)] = String(cString: v)
                    }
                }
                sqlite3_finalize(stmt)
            }
            DispatchQueue.main.async { done(out) }
        }
    }

    /// cid -> synced_up_to, for one chat or all (on `queue` only). Rows with no mark are left out.
    private func syncedMarks(uid: String, cid: String?) -> [String: Int64] {
        var out: [String: Int64] = [:]
        guard let db = handle(uid) else { return out }
        var stmt: OpaquePointer?
        let sql = cid == nil
            ? "SELECT cid, synced_up_to FROM chats WHERE synced_up_to IS NOT NULL"
            : "SELECT cid, synced_up_to FROM chats WHERE cid = ? AND synced_up_to IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        if let cid { Self.bind(stmt, 1, cid) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            out[String(cString: c)] = sqlite3_column_int64(stmt, 1)
        }
        return out
    }

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
        // ⛔ IN THE APP GROUP (2026-11-12): the notification extension must reach it to keep the icon
        // badge right while the app is closed. Nothing shipped with the old place, so no move is needed.
        // A lock held there while suspended gets the app killed (0xDEAD10CC): see `closeForBackground`.
        guard !uid.isEmpty, uid.allSatisfy({ $0.isLetter || $0.isNumber }),
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.kulan.messenger.native")
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
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

    /// Restore at sign-in (agreed with Android 2026-11-12): does this phone already hold history for
    /// `uid`? Yes when meta "restored" or "migrated" is set, or any message row is filed. Blocking:
    /// call it off the main thread.
    func hasHistory(uid: String) -> Bool {
        guard !uid.isEmpty else { return false }
        return queue.sync {
            guard let db = self.handle(uid) else { return false }
            var stmt: OpaquePointer?
            let sql = "SELECT (SELECT COUNT(*) FROM meta WHERE key IN ('restored', 'migrated')) + (SELECT COUNT(*) FROM (SELECT 1 FROM messages LIMIT 1))"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int64(stmt, 0) > 0
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
        let written = insertRaw(uid: uid, table: "chats", columns: Self.chatColumns,
                                required: ["cid": .text], defaults: [:], rows: rows)
        // D5 (owner 2026-11-12): the chats rows are the last thing a restore files; every chat's list
        // row is worked out again from the messages now here (a row written by the other app or an
        // older backup does not have to agree with this one).
        rebuildAllSummaries(uid: uid)
        return written
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

// MARK: - The chat list's rows from the phone (plan D5)

/// ⛔ D5, THE CHAT LIST FROM THE PHONE (owner 2026-11-12, plan decision D5): a private chat's preview
/// line, its time and its unread number come from this database, so the server can later stop
/// keeping previews. The `chats` row of each chat follows its messages:
/// - `last_id`, `last_at`: the newest message still here (a group skips deleted ones, as the server's
///   own summary does; a disappearing one that ran out is not counted).
/// - `unread`: messages from others after my read mark (not notices, calls or pin lines, the same
///   ones the server leaves out of its count). NULL while this phone has no read mark yet.
/// - `body`: JSON {text (preview, already decrypted), type, authorId, deleted, readAt}. `readAt` is my
///   read mark (server ms): reading the chat moves it (`markRead`), never back. Other keys in the body
///   are kept as they are.
/// Worked out again after every write that can change it (upsert, purge, clear, read, restore), on
/// the database queue. Only the overlay in ConversationsRepository reads it; the server's fields
/// stay the fallback.
extension LocalMessageDB {
    /// One chat's list row as this phone sees it.
    struct Summary: Equatable {
        let lastId: String
        /// Server time of the newest message, ms.
        let lastAt: Double
        /// nil = no read mark on this phone yet (the server's number is used).
        let unread: Int?
        /// The preview line, already decrypted; media in the same words the send path writes.
        let text: String
        let type: String
        let authorId: String
        let deleted: Bool
        /// When the newest message runs out (ms), nil = never.
        let expiresAt: Double?
        var imageUrl: String? = nil
        var imageEnc: EncMeta? = nil
        var images: [Conversation.ListThumb] = []

        /// The line can stand in for the server's: real words, never a sealed or half-open one.
        var usable: Bool {
            guard !text.isEmpty, text != "…", text != "🔒", text != "[old message]" else { return false }
            return !text.hasPrefix("enc:") && !text.hasPrefix("enc1:") && !text.hasPrefix("encg1:")
        }
        /// A member's own words in a group (the list puts their name in front), not a notice or a call.
        var isMemberWords: Bool { !deleted && type != "system" && type != "call" }
    }

    /// Posted on the main thread after the summaries changed (ConversationsRepository reloads them).
    static let summariesChanged = Notification.Name("LocalMessageDB.summariesChanged")

    /// Every chat's summary in one read, cid -> Summary. Chats with no message here are left out.
    /// `done` runs on the main thread.
    func chatSummaries(uid: String, done: @escaping ([String: Summary]) -> Void) {
        queue.async {
            let out = self.readSummaries(uid)
            DispatchQueue.main.async { done(out) }
        }
    }

    /// ⛔ I READ THIS CHAT (owner 2026-11-12): my read mark moves up to the newest message here, or to
    /// `upTo` (the server's newest time for the chat, ms) when that is later. Never backwards.
    func markRead(cid: String, uid: String, upTo serverMillis: Double) {
        guard LocalSummaries.enabled, !cid.isEmpty, !uid.isEmpty else { return }
        let floor = serverMillis > 0 && serverMillis.isFinite ? Int64(serverMillis.rounded(.up)) : 0
        queue.async {
            guard let db = self.handle(uid) else { return }
            let row = self.chatRow(db, cid: cid)
            let old = (row.body["readAt"] as? NSNumber)?.int64Value
            let mark = max(old ?? 0, floor, row.lastAt ?? 0)
            if let old, old >= mark { return }   // already read that far: no write
            var body = row.body
            body["readAt"] = NSNumber(value: mark)
            self.writeChatBody(db, cid: cid, body: body)
            self.refreshSummary(db, cid: cid, uid: uid)
            Self.announceSummaries()
        }
    }

    // MARK: Inside (on `queue` only)

    /// Works out `cid`'s chats row again from its messages (see the note on this extension).
    func refreshSummary(_ db: OpaquePointer, cid: String, uid: String) {
        guard LocalSummaries.enabled else { return }
        let group = !cid.contains("_")   // the server's own test (ChatService.summaryOfNewest)
        let now = Self.ms(Date())
        let existing = chatRow(db, cid: cid)
        var body = existing.body
        let readAt = (body["readAt"] as? NSNumber)?.int64Value
        for k in ["text", "type", "authorId", "deleted"] { body[k] = nil }
        var lastId: String?
        var lastAt: Int64?
        var stmt: OpaquePointer?
        let sql = "SELECT id, created_at, sender, type, deleted, body FROM messages WHERE cid = ?1"
            + " AND (expires_at IS NULL OR expires_at > ?2)" + (group ? " AND deleted = 0" : "")
            + " ORDER BY created_at DESC LIMIT 1"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            Self.bind(stmt, 1, cid)
            sqlite3_bind_int64(stmt, 2, now)
            if sqlite3_step(stmt) == SQLITE_ROW, let id = Self.column(stmt, 0) {
                lastId = id
                lastAt = sqlite3_column_int64(stmt, 1)
                let type = Self.column(stmt, 3) ?? "text"
                let deleted = sqlite3_column_int64(stmt, 4) != 0
                let raw = Self.column(stmt, 5) ?? "{}"
                let m: Message? = raw == "{}" ? nil
                    : raw.data(using: .utf8).flatMap { try? Self.decoder.decode(Message.self, from: $0) }
                body["text"] = Self.previewText(m, type: type, deleted: deleted)
                body["type"] = type
                body["authorId"] = Self.column(stmt, 2) ?? ""
                body["deleted"] = deleted
            }
        }
        sqlite3_finalize(stmt)
        guard existing.exists || lastId != nil else { return }   // nothing to say about this chat
        let unread: Int64? = readAt.map { countUnread(db, cid: cid, uid: uid, after: $0, now: now) }
        let up = """
            INSERT INTO chats (cid, last_id, last_at, unread, body) VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(cid) DO UPDATE SET last_id = excluded.last_id, last_at = excluded.last_at,
              unread = excluded.unread, body = excluded.body
            """
        var w: OpaquePointer?
        guard sqlite3_prepare_v2(db, up, -1, &w, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(w) }
        Self.bind(w, 1, cid)
        if let lastId { Self.bind(w, 2, lastId) } else { sqlite3_bind_null(w, 2) }
        if let lastAt { sqlite3_bind_int64(w, 3, lastAt) } else { sqlite3_bind_null(w, 3) }
        if let unread { sqlite3_bind_int64(w, 4, unread) } else { sqlite3_bind_null(w, 4) }
        if let s = Self.jsonString(body) { Self.bind(w, 5, s) } else { sqlite3_bind_null(w, 5) }
        sqlite3_step(w)
    }

    /// Messages from others after `after` that count as unread (as the server counts: not a notice,
    /// a call or a pin line). Capped at 1000 rows; the badge never shows more.
    private func countUnread(_ db: OpaquePointer, cid: String, uid: String, after: Int64, now: Int64) -> Int64 {
        var stmt: OpaquePointer?
        let sql = """
            SELECT body FROM messages WHERE cid = ?1 AND created_at > ?2 AND sender IS NOT ?3 AND deleted = 0
              AND (expires_at IS NULL OR expires_at > ?4) AND (type IS NULL OR type NOT IN ('system', 'call'))
            LIMIT 1000
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, cid)
        sqlite3_bind_int64(stmt, 2, after)
        Self.bind(stmt, 3, uid)
        sqlite3_bind_int64(stmt, 4, now)
        // A pin line is sent without raising the count (ThreadView, countsAsUnread: false).
        let pin = "\"text\":\"" + Message.pinMarker
        var n: Int64 = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let b = Self.column(stmt, 0), b.contains(pin) { continue }
            n += 1
        }
        return n
    }

    /// The chats row of `cid`: whether it exists, its last_at and its body as a dictionary.
    private func chatRow(_ db: OpaquePointer, cid: String) -> (exists: Bool, lastAt: Int64?, body: [String: Any]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT last_at, body FROM chats WHERE cid = ?", -1, &stmt, nil) == SQLITE_OK else {
            return (false, nil, [:])
        }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, cid)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (false, nil, [:]) }
        let lastAt: Int64? = sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0)
        return (true, lastAt, Self.jsonObject(Self.column(stmt, 1)))
    }

    private func writeChatBody(_ db: OpaquePointer, cid: String, body: [String: Any]) {
        guard let s = Self.jsonString(body) else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO chats (cid, body) VALUES (?, ?) ON CONFLICT(cid) DO UPDATE SET body = excluded.body",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        Self.bind(stmt, 1, cid)
        Self.bind(stmt, 2, s)
        sqlite3_step(stmt)
    }

    /// The cids one query returns (its one parameter, ?1, is an integer).
    func cids(_ db: OpaquePointer, _ sql: String, _ value: Int64) -> [String] {
        var out: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, value)
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = Self.column(stmt, 0) { out.append(c) }
        }
        return out
    }

    /// Every chat with messages here, worked out again (after a restore). Waits for the queue, so
    /// never call it ON the queue.
    func rebuildAllSummaries(uid: String) {
        guard LocalSummaries.enabled, !uid.isEmpty else { return }
        queue.sync {
            guard let db = self.handle(uid) else { return }
            let all = self.cids(db, "SELECT DISTINCT cid FROM messages WHERE ?1 = ?1", 0)
                + self.cids(db, "SELECT cid FROM chats WHERE last_id IS NOT NULL AND ?1 = ?1", 0)
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for cid in Set(all) { self.refreshSummary(db, cid: cid, uid: uid) }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
        Self.announceSummaries()
    }

    private func readSummaries(_ uid: String) -> [String: Summary] {
        var out: [String: Summary] = [:]
        guard LocalSummaries.enabled, let db = handle(uid) else { return out }
        var stmt: OpaquePointer?
        let sql = """
            SELECT c.cid, c.last_id, c.last_at, c.unread, c.body, m.body, m.expires_at
            FROM chats c LEFT JOIN messages m ON m.cid = c.cid AND m.id = c.last_id
            WHERE c.last_id IS NOT NULL AND c.last_at IS NOT NULL
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cid = Self.column(stmt, 0), let lastId = Self.column(stmt, 1) else { continue }
            let body = Self.jsonObject(Self.column(stmt, 4))
            // A row this build did not work out (the other app's, a restore not yet rebuilt) is skipped.
            guard let text = body["text"] as? String else { continue }
            let type = body["type"] as? String ?? "text"
            let deleted = (body["deleted"] as? NSNumber)?.boolValue ?? false
            var s = Summary(
                lastId: lastId,
                lastAt: Double(sqlite3_column_int64(stmt, 2)),
                unread: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3)),
                text: text, type: type,
                authorId: body["authorId"] as? String ?? "",
                deleted: deleted,
                expiresAt: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Double(sqlite3_column_int64(stmt, 6)))
            // The list's thumbnail: the same picture the send path puts on the conversation.
            if !deleted, ["image", "video", "album"].contains(type), let raw = Self.column(stmt, 5), raw != "{}",
               let data = raw.data(using: .utf8), let m = try? Self.decoder.decode(Message.self, from: data) {
                Self.fillThumbnail(&s, from: m)
            }
            out[cid] = s
        }
        return out
    }

    private static func fillThumbnail(_ s: inout Summary, from m: Message) {
        switch s.type {
        case "image":
            guard !m.viewOnce, let u = m.imageUrl, !u.isEmpty, let e = m.enc else { return }
            s.imageUrl = u; s.imageEnc = e
        case "video":
            guard let u = m.thumbUrl, !u.isEmpty, let e = m.thumbEnc else { return }
            s.imageUrl = u; s.imageEnc = e
        case "album":
            let tiles = m.album.filter { !$0.imageUrl.isEmpty }
            guard let first = tiles.first(where: { $0.kind == "image" }) ?? tiles.first else { return }
            s.imageUrl = first.imageUrl; s.imageEnc = first.enc
            guard tiles.count > 1 else { return }
            let rest = tiles.filter { $0.imageUrl != first.imageUrl }
            s.images = ([first] + rest).prefix(3).map { Conversation.ListThumb(url: $0.imageUrl, enc: $0.enc) }
        default:
            return
        }
    }

    /// The preview line for a message, in the words the send paths write on the conversation
    /// (ChatService: "📷 Photo", "🎤 Voice message · 0:53", "📞 Missed call", ...). `m` nil = the body
    /// was emptied (an opened view-once).
    static func previewText(_ m: Message?, type: String, deleted: Bool) -> String {
        if deleted { return "This message was deleted" }
        guard let m else {
            switch type {
            case "image": return "View-once photo"
            case "audio": return "🎤 One-time voice message"
            default: return ""
            }
        }
        switch type {
        case "sticker": return StickerSend.label(emoji: m.stickerEmoji)
        case "image": return m.viewOnce ? "View-once photo" : "📷 Photo"
        case "album":
            let videos = m.album.filter { $0.kind == "video" }.count
            let photos = m.album.count - videos
            if videos > 0 && photos > 0 { return "🎬 \(m.album.count) Media" }
            if videos > 0 { return "🎥 \(videos) Video\(videos > 1 ? "s" : "")" }
            return photos > 1 ? "📷 \(photos) Photos" : "📷 Photo"
        case "video":
            guard let d = m.duration, d > 0 else { return "🎥 Video" }
            return "🎥 Video · " + ChatService.voiceDurationLabel(d)
        case "audio":
            if m.viewOnce { return "🎤 One-time voice message" }
            guard let d = m.duration, d > 0 else { return "🎤 Voice message" }
            return "🎤 Voice message · " + ChatService.voiceDurationLabel(d)
        case "file": return "📄 File"
        case "gif": return "GIF"
        case "call":
            // A declined call reads as missed everywhere (owner 2026-08-12).
            let missed = m.callOutcome == "missed" || m.callOutcome == "declined"
            if missed { return m.callVideo ? "📹 Missed video call" : "📞 Missed call" }
            return m.callVideo ? "📹 Video call" : "📞 Call"
        default:
            if m.text.isEmpty, m.quoteId != nil { return "Quoted post" }
            return m.text
        }
    }

    static func announceSummaries() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: summariesChanged, object: nil) }
    }

    private static func column(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private static func jsonObject(_ s: String?) -> [String: Any] {
        guard let s, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func jsonString(_ obj: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// ⛔ THE D5 SWITCH (owner 2026-11-12): false turns the phone-side chat list rows off at once; every
/// row, count and badge goes back to the server's fields, and the database stops working them out.
enum LocalSummaries {
    static let enabled = true
}
