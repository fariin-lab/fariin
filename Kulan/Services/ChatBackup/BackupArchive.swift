import Foundation
import Sodium

/// ⛔ CHAT BACKUP IS OFF. Phase 3 of the device-storage plan (Documents/fariin-plans/
/// 2026-11-12-device-storage-plan.md). The engine (BackupArchive, BackupStoreKey, ICloudBackup) is
/// built but nothing in the app calls it while this is false, and the engine refuses to run.
/// Turning it on also needs the iCloud (CloudKit) capability on the App ID in the Apple Developer
/// portal, then the entitlement in Kulan.entitlements; without both, CloudKit stops the app.
enum ChatBackup {
    static let enabled = false
}

/// BACKUP ARCHIVE FORMAT v1 (agreed with Android 2026-11-12; the Android app writes and reads the same
/// bytes, so a backup made on one opens on the other):
///
/// - Crypto: crypto_secretbox_easy (XSalsa20-Poly1305). Every encrypted file is
///   `24-byte random nonce || secretbox`. The archive key is 32 random bytes, new for every backup.
/// - `header.json` (plain): `{"v":1,"made":ms,"kdf":{"salt":b64,"ops":3,"mem":67108864} or null,
///   "wrapped":{"store":b64,"password":b64}}`. `store` is nonce||secretbox(archive key) under the
///   platform-store key (BackupStoreKey); `password` is the same under
///   Argon2id13(password UTF-8, salt 16 bytes, ops, mem, 32 bytes out) and is absent without a
///   password. All bytes are standard base64 with padding.
/// - `manifest.bin` (encrypted): `{"uid":..,"count":all message rows,"chunks":["m-0001.bin",..],"made":ms}`.
///   `chunks` lists the message chunks only; `chats.bin` is always there.
/// - `m-0001.bin`, `m-0002.bin`, ... (encrypted): JSON lines, one messages row per line (columns
///   cid, id, created_at, sender, type, deleted, edited_at, expires_at, body, updated_at; a null
///   column is JSON null), every line ending in "\n", rows ordered by created_at, at most 2000 rows
///   and at most 2 MiB (2,097,152 bytes of plain text) per chunk. A single row bigger than that
///   goes alone in its chunk. `body` is the shared WIRE body (WireBody), not this app's own JSON;
///   a deleted or opened view-once row keeps "{}".
/// - `chats.bin` (encrypted): JSON lines of the chats table rows, same rules.
/// - Media are not in v1.
enum BackupArchive {
    static let version = 1
    static let opsLimit = 3
    static let memLimit = 67_108_864   // 64 MiB
    static let saltBytes = 16
    static let keyBytes = 32
    static let nonceBytes = 24
    static let maxRowsPerChunk = 2000
    static let maxBytesPerChunk = 2 * 1024 * 1024
    /// A backup password: any characters, at least this many. The 64-digit key is a password of
    /// 64 digits, so it goes through the same path.
    static let minPasswordLength = 8

    static let headerName = "header.json"
    static let manifestName = "manifest.bin"
    static let chatsName = "chats.bin"
    static func chunkName(_ n: Int) -> String { String(format: "m-%04d.bin", n) }

    enum Failure: LocalizedError {
        case crypto
        case damaged
        case newerVersion
        case wrongPassword
        case needsPassword
        case noKey
        case otherAccount
        case weakPassword

        var errorDescription: String? {
            switch self {
            case .crypto: return "Couldn't lock the backup on this phone."
            case .damaged: return "The backup could not be opened."
            case .newerVersion: return "This backup was made by a newer Fariin. Update the app first."
            case .wrongPassword: return "Wrong backup password."
            case .needsPassword: return "Enter your backup password to restore."
            case .noKey: return "This phone can't open the backup. Sign in to the same iCloud account, or use your backup password."
            case .otherAccount: return "This backup belongs to another Fariin account."
            case .weakPassword: return "Use at least \(BackupArchive.minPasswordLength) characters."
            }
        }
    }

    struct Kdf {
        var salt: Bytes
        var ops: Int
        var mem: Int
    }

    struct Header {
        var v: Int
        var made: Int64
        var kdf: Kdf?
        var wrappedStore: Bytes?
        var wrappedPassword: Bytes?
    }

    struct Manifest {
        var uid: String
        var count: Int
        var chunks: [String]
        var made: Int64
    }

    private static let sodium = Sodium()

    // MARK: - Crypto

    static func newKey() -> Bytes? {
        guard let k = sodium.randomBytes.buf(length: keyBytes), k.count == keyBytes else { return nil }
        return k
    }

    /// `nonce || secretbox(plain)` with a fresh random nonce.
    static func seal(_ plain: Bytes, key: Bytes) -> Bytes? {
        guard key.count == keyBytes,
              let sealed: (authenticatedCipherText: Bytes, nonce: Bytes) =
                sodium.secretBox.seal(message: plain, secretKey: key),
              sealed.nonce.count == nonceBytes else { return nil }
        return sealed.nonce + sealed.authenticatedCipherText
    }

    /// Opens `nonce || secretbox`; nil when the key is wrong or the bytes were changed.
    static func open(_ file: Bytes, key: Bytes) -> Bytes? {
        guard key.count == keyBytes, file.count > nonceBytes else { return nil }
        let nonce = Bytes(file[0..<nonceBytes])
        let box = Bytes(file[nonceBytes...])
        return sodium.secretBox.open(authenticatedCipherText: box, secretKey: key, nonce: nonce)
    }

    /// Argon2id13 of the password: 64 MiB and a few hundred ms, so never on the main thread.
    static func passwordKey(_ password: String, kdf: Kdf) async -> Bytes? {
        let pw = Bytes(password.utf8)
        return await Task.detached(priority: .userInitiated) { () -> Bytes? in
            guard let out = Sodium().pwHash.hash(outputLength: BackupArchive.keyBytes, passwd: pw, salt: kdf.salt,
                                                 opsLimit: kdf.ops, memLimit: kdf.mem, alg: .Argon2ID13),
                  out.count == BackupArchive.keyBytes else { return nil }
            return out
        }.value
    }

    // MARK: - header.json

    /// A new header for `archiveKey`: wrapped under the store key, and under the password too when
    /// there is one (a new salt every time).
    static func makeHeader(archiveKey: Bytes, storeKey: Bytes, password: String?, made: Int64) async throws -> Header {
        guard let store = seal(archiveKey, key: storeKey) else { throw Failure.crypto }
        var header = Header(v: version, made: made, kdf: nil, wrappedStore: store, wrappedPassword: nil)
        if let password, !password.isEmpty {
            guard password.count >= minPasswordLength else { throw Failure.weakPassword }
            guard let salt = sodium.randomBytes.buf(length: saltBytes), salt.count == saltBytes else { throw Failure.crypto }
            let kdf = Kdf(salt: salt, ops: opsLimit, mem: memLimit)
            guard let pk = await passwordKey(password, kdf: kdf),
                  let wrapped = seal(archiveKey, key: pk) else { throw Failure.crypto }
            header.kdf = kdf
            header.wrappedPassword = wrapped
        }
        return header
    }

    static func encodeHeader(_ h: Header) throws -> Data {
        var wrapped: [String: Any] = [:]
        if let s = h.wrappedStore { wrapped["store"] = b64(s) }
        if let p = h.wrappedPassword { wrapped["password"] = b64(p) }
        let kdf: Any
        if let k = h.kdf {
            kdf = ["salt": b64(k.salt), "ops": k.ops, "mem": k.mem] as [String: Any]
        } else {
            kdf = NSNull()
        }
        let obj: [String: Any] = ["v": h.v, "made": NSNumber(value: h.made), "kdf": kdf, "wrapped": wrapped]
        return try json(obj)
    }

    static func parseHeader(_ data: Data) throws -> Header {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = (obj["v"] as? NSNumber)?.intValue else { throw Failure.damaged }
        guard v <= version else { throw Failure.newerVersion }
        let made = (obj["made"] as? NSNumber)?.int64Value ?? 0
        var kdf: Kdf?
        if let k = obj["kdf"] as? [String: Any] {
            guard let salt = unb64(k["salt"]), salt.count == saltBytes,
                  let ops = (k["ops"] as? NSNumber)?.intValue, let mem = (k["mem"] as? NSNumber)?.intValue,
                  // A changed header must not make this phone spend minutes or gigabytes.
                  (1...10).contains(ops), (8_192...1_073_741_824).contains(mem) else { throw Failure.damaged }
            kdf = Kdf(salt: salt, ops: ops, mem: mem)
        }
        let wrapped = obj["wrapped"] as? [String: Any] ?? [:]
        return Header(v: v, made: made, kdf: kdf,
                      wrappedStore: unb64(wrapped["store"]), wrappedPassword: unb64(wrapped["password"]))
    }

    /// The archive key, from the store key first, then the password. Throws `needsPassword` when
    /// only a password could open it and none was given, `wrongPassword` when it does not.
    static func unwrap(_ h: Header, storeKey: Bytes?, password: String?) async throws -> Bytes {
        if let storeKey, let w = h.wrappedStore, let key = open(w, key: storeKey), key.count == keyBytes {
            return key
        }
        guard let w = h.wrappedPassword, let kdf = h.kdf else { throw Failure.noKey }
        guard let password, !password.isEmpty else { throw Failure.needsPassword }
        guard let pk = await passwordKey(password, kdf: kdf) else { throw Failure.crypto }
        guard let key = open(w, key: pk), key.count == keyBytes else { throw Failure.wrongPassword }
        return key
    }

    // MARK: - Writing

    /// Writes the encrypted files of one backup into `dir` (manifest.bin, m-0001.bin..., chats.bin;
    /// header.json is the caller's, it needs the store key). Reads the database a page at a time and
    /// keeps one chunk in memory. Returns the file names written. Run it off the main thread.
    ///
    /// ⛔ safety review 2026-11-12: the chats rows (with their marks) are read FIRST, then the
    /// messages. The database has one connection whose queue is let go between pages, so one read
    /// transaction cannot span them; reading the marks first is what keeps the archive honest: a
    /// mark only says rows up to it were filed BEFORE it was read, and those rows are then read
    /// after it (rows are only added later, or removed on purpose: an expired message, Clear
    /// History). A chat with any message row left out (its body would not convert to the wire
    /// body) gets NO `synced_up_to` in chats.bin. A database read that fails stops the backup.
    static func writeFiles(uid: String, archiveKey: Bytes, made: Int64, to dir: URL,
                           db: LocalMessageDB = .shared) throws -> [String] {
        var names: [String] = []
        var chunks: [String] = []
        var buffer = Data()
        var rowsInBuffer = 0
        var count = 0
        let chatRows = try db.allChatRows(uid: uid)   // first: see above
        var lost = LocalMessageDB.RowLoss()

        func flush() throws {
            guard rowsInBuffer > 0 else { return }
            let name = chunkName(chunks.count + 1)
            try writeSealed(Bytes(buffer), key: archiveKey, to: dir.appendingPathComponent(name))
            chunks.append(name)
            names.append(name)
            buffer.removeAll(keepingCapacity: true)
            rowsInBuffer = 0
        }

        try db.allRows(uid: uid) { page in
            for var row in page {
                // A body that will not convert is left out rather than written in this app's own shape.
                guard let wire = wireBody(row) else { lost.add(row); continue }
                row["body"] = wire
                let line = try jsonLine(row, columns: LocalMessageDB.messageColumns)
                if rowsInBuffer >= maxRowsPerChunk || (rowsInBuffer > 0 && buffer.count + line.count > maxBytesPerChunk) {
                    try flush()
                }
                buffer.append(line)
                rowsInBuffer += 1
                count += 1
            }
        }
        try flush()

        var chats = Data()
        for row in lost.withoutMarks(chatRows) {
            chats.append(try jsonLine(row, columns: LocalMessageDB.chatColumns))
        }
        try writeSealed(Bytes(chats), key: archiveKey, to: dir.appendingPathComponent(chatsName))
        names.append(chatsName)

        let manifest: [String: Any] = ["uid": uid, "count": count, "chunks": chunks, "made": NSNumber(value: made)]
        try writeSealed(Bytes(try json(manifest)), key: archiveKey, to: dir.appendingPathComponent(manifestName))
        names.insert(manifestName, at: 0)
        return names
    }

    // MARK: - Reading

    static func readManifest(_ file: Data, key: Bytes) throws -> Manifest {
        guard let plain = open(Bytes(file), key: key),
              let obj = try? JSONSerialization.jsonObject(with: Data(plain)) as? [String: Any],
              let uid = obj["uid"] as? String,
              let chunks = obj["chunks"] as? [String] else { throw Failure.damaged }
        // Only names of the agreed shape: a changed manifest must not ask for other files.
        return Manifest(uid: uid, count: (obj["count"] as? NSNumber)?.intValue ?? 0,
                        chunks: chunks.filter(isChunkName),
                        made: (obj["made"] as? NSNumber)?.int64Value ?? 0)
    }

    /// The rows of one encrypted chunk (m-NNNN.bin or chats.bin). Lines that do not parse are skipped.
    static func readRows(_ file: Data, key: Bytes) throws -> [LocalMessageDB.RawRow] {
        guard let plain = open(Bytes(file), key: key) else { throw Failure.damaged }
        var rows: [LocalMessageDB.RawRow] = []
        for line in plain.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                rows.append(obj)
            }
        }
        return rows
    }

    /// The rows of one message chunk, each `body` turned from the wire body back into this app's own
    /// Message JSON (what LocalMessageDB files). Rows whose body will not convert, and lines that do
    /// not parse, are skipped and reported in `lost` (safety review 2026-11-12): their chats get no
    /// mark from this backup (`RowLoss.withoutMarks`).
    static func readMessageRows(_ file: Data, key: Bytes) throws -> (rows: [LocalMessageDB.RawRow], lost: LocalMessageDB.RowLoss) {
        guard let plain = open(Bytes(file), key: key) else { throw Failure.damaged }
        var rows: [LocalMessageDB.RawRow] = []
        var lost = LocalMessageDB.RowLoss()
        for line in plain.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard var row = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                lost.unknown = true   // whose chat it was cannot be told
                continue
            }
            guard let own = ownBody(row) else { lost.add(row); continue }
            row["body"] = own
            rows.append(row)
        }
        return (rows, lost)
    }

    static func isChunkName(_ s: String) -> Bool {
        guard s.count == 10, s.hasPrefix("m-"), s.hasSuffix(".bin") else { return false }
        return s.dropFirst(2).prefix(4).allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: - Private

    /// The same JSON shape LocalMessageDB reads and writes.
    private static let messageEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e
    }()
    private static let messageDecoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d
    }()

    /// Database body -> wire body. "{}" (and an empty or missing body) is kept as it is.
    private static func wireBody(_ row: LocalMessageDB.RawRow) -> Any? {
        guard let body = row["body"] as? String else { return row["body"] ?? NSNull() }
        if body == "{}" || body.isEmpty { return body }
        guard let cid = row["cid"] as? String, let data = body.data(using: .utf8),
              let m = try? messageDecoder.decode(Message.self, from: data),
              let wire = try? json(WireBody.encode(m, cid: cid)),
              let s = String(data: wire, encoding: .utf8) else { return nil }
        return s
    }

    /// Wire body -> database body. "{}" (and an empty or missing body) is kept as it is.
    private static func ownBody(_ row: LocalMessageDB.RawRow) -> Any? {
        guard let body = row["body"] as? String else { return row["body"] ?? NSNull() }
        if body == "{}" || body.isEmpty { return body }
        guard let cid = row["cid"] as? String, let data = body.data(using: .utf8),
              let wire = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let m = WireBody.decode(wire, cid: cid),
              let own = try? messageEncoder.encode(m),
              let s = String(data: own, encoding: .utf8) else { return nil }
        return s
    }

    private static func writeSealed(_ plain: Bytes, key: Bytes, to url: URL) throws {
        guard let sealed = seal(plain, key: key) else { throw Failure.crypto }
        try Data(sealed).write(to: url, options: .atomic)
    }

    /// One row as a JSON line: only the agreed columns, null where empty, "\n" at the end.
    private static func jsonLine(_ row: LocalMessageDB.RawRow, columns: [String]) throws -> Data {
        var obj: [String: Any] = [:]
        for c in columns { obj[c] = row[c] ?? NSNull() }
        var d = try json(obj)
        d.append(0x0A)
        return d
    }

    private static func json(_ obj: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func b64(_ b: Bytes) -> String { Data(b).base64EncodedString() }

    private static func unb64(_ v: Any?) -> Bytes? {
        guard let s = v as? String, let d = Data(base64Encoded: s) else { return nil }
        return Bytes(d)
    }
}
