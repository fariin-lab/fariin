import Foundation
import Sodium
import FirebaseAuth
import FirebaseFunctions

/// ⛔ BACKUP PIN (owner 2026-11-12, both apps, ONE FORMAT). The chat key lives only on this phone, so
/// deleting Fariin or changing phones lost every older message (the "Messages from before you signed
/// in on this device" notice). With a Backup PIN the key is saved on the server LOCKED with the PIN:
///
/// - `out = Argon2id13(64 bytes, PIN digits as UTF-8, 16-byte salt, ops 3, mem 64 MiB)`
/// - the first 32 bytes lock a secretbox holding `{"v":1,"sk":..,"pk":..,"made":ms}`,
///   the last 32 are the `auth` the server checks before it hands the box back;
/// - every byte travels as standard base64 with padding.
///
/// The server (functions-account key-backup.js) never sees the PIN or the lock key, counts wrong
/// tries (5 lock 1 h, then 4 h, then 24 h; 10 in a row delete the backup) and never lets a client
/// read `keyBackups`. Android (crypto/KeyBackup.kt) writes and reads the same bytes, so a backup made
/// on one opens on the other.
enum KeyBackup {
    static let opsLimit = 3
    static let memLimit = 67_108_864   // 64 MiB
    static let minDigits = 6

    struct Status {
        var exists = false
        var salt: Bytes = []
        var ops = KeyBackup.opsLimit
        var mem = KeyBackup.memLimit
        var pk = ""
        /// As the server sent it, only compared for "Skip" (`skipped`).
        var updatedAt = ""
        var triesLeft = 10
        var lockedUntil: Double = 0   // ms
    }

    enum Failure: LocalizedError {
        case wrong(triesLeft: Int)
        case locked(until: Date)
        case gone(wiped: Bool)
        case damaged
        case other(String)

        var errorDescription: String? {
            switch self {
            case .wrong(let n):
                return "Wrong PIN. \(n) \(n == 1 ? "try" : "tries") left before the backup is deleted."
            case .locked(let until):
                return "Too many wrong tries. Try again after \(until.formatted(date: .omitted, time: .shortened))."
            case .gone(let wiped):
                return wiped ? "The backup was deleted after too many wrong PINs." : "There is no backup for this account."
            case .damaged:
                return "The saved key could not be opened."
            case .other(let s):
                return s
            }
        }
    }

    private static var functions: Functions { Functions.functions(region: "me-central1") }
    private static let sodium = Sodium()

    // MARK: - Server

    static func status() async throws -> Status {
        let res = try await functions.httpsCallable("keyBackupStatus").call([String: Any]())
        let d = res.data as? [String: Any] ?? [:]
        var s = Status()
        s.exists = d["exists"] as? Bool ?? false
        s.salt = (d["salt"] as? String).flatMap { Data(base64Encoded: $0) }.map { Bytes($0) } ?? []
        s.ops = (d["ops"] as? NSNumber)?.intValue ?? opsLimit
        s.mem = (d["mem"] as? NSNumber)?.intValue ?? memLimit
        s.pk = d["pk"] as? String ?? ""
        if let u = d["updatedAt"] { s.updatedAt = "\(u)" }
        s.triesLeft = (d["triesLeft"] as? NSNumber)?.intValue ?? 10
        s.lockedUntil = (d["lockedUntil"] as? NSNumber)?.doubleValue ?? 0
        rememberOn(s.exists)
        return s
    }

    /// Locks this phone's key with `pin` and saves it (a new salt every time, so Change PIN is a save).
    static func save(pin: String) async throws {
        // The server takes only a key the account has published; make sure ours is out first.
        await Crypto.shared.publishPublicKey()
        guard let id = await Crypto.shared.identityForBackup() else {
            throw Failure.other("Your chat key isn't ready yet. Try again in a moment.")
        }
        let salt = sodium.randomBytes.buf(length: 16) ?? []
        guard salt.count == 16, let keys = await derive(pin: pin, salt: salt, ops: opsLimit, mem: memLimit) else {
            throw Failure.other("Couldn't lock the key on this phone.")
        }
        let plain: [String: Any] = ["v": 1,
                                    "sk": Data(id.sk).base64EncodedString(),
                                    "pk": Data(id.pk).base64EncodedString(),
                                    "made": id.madeMs]
        guard let json = try? JSONSerialization.data(withJSONObject: plain),
              let sealed: (authenticatedCipherText: Bytes, nonce: Bytes) =
                sodium.secretBox.seal(message: Bytes(json), secretKey: keys.lock) else {
            throw Failure.other("Couldn't lock the key on this phone.")
        }
        _ = try await functions.httpsCallable("keyBackupSave").call([
            "salt": Data(salt).base64EncodedString(),
            "ops": opsLimit,
            "mem": memLimit,
            "auth": Data(keys.auth).base64EncodedString(),
            "nonce": Data(sealed.nonce).base64EncodedString(),
            "box": Data(sealed.authenticatedCipherText).base64EncodedString(),
            "pk": Data(id.pk).base64EncodedString(),
        ])
        rememberOn(true)
        markChecked()
    }

    /// Opens the backup with `pin` and makes its key this phone's key. Throws `Failure`.
    static func restore(pin: String, status: Status) async throws {
        guard status.salt.count == 16,
              let keys = await derive(pin: pin, salt: status.salt, ops: status.ops, mem: status.mem) else {
            throw Failure.damaged
        }
        let d: [String: Any]
        do {
            let res = try await functions.httpsCallable("keyBackupRestore")
                .call(["auth": Data(keys.auth).base64EncodedString()])
            d = res.data as? [String: Any] ?? [:]
        } catch {
            throw failure(from: error)
        }
        guard let nonce = (d["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let box = (d["box"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(box),
                                                  secretKey: keys.lock, nonce: Bytes(nonce)),
              let obj = try? JSONSerialization.jsonObject(with: Data(opened)) as? [String: Any],
              let sk = (obj["sk"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let pk = (obj["pk"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw Failure.damaged
        }
        let made = (obj["made"] as? NSNumber)?.int64Value ?? 0
        do {
            try Crypto.shared.adoptRestoredIdentity(sk: Bytes(sk), pk: Bytes(pk), madeMs: made)
        } catch {
            throw Failure.other(error.localizedDescription)
        }
        // Every chat read with the old key reads again with this one.
        await MainActor.run {
            ThreadMessageCache.shared.removeAll()
            GalleryCache.removeAll()
        }
        rememberOn(true)
        markChecked()
    }

    static func delete() async throws {
        _ = try await functions.httpsCallable("keyBackupDelete").call([String: Any]())
        rememberOn(false)
    }

    // MARK: - After sign-in

    /// The backup to offer on "Restore your messages", or nil. Asked once per key this phone holds:
    /// once answered (no backup, the backup IS this key, or Skip), it is not asked again until this
    /// phone's key changes. Skip is remembered for that backup's `updatedAt` only.
    static func backupToOffer() async -> Status? {
        guard let uid = Auth.auth().currentUser?.uid,
              let mine = await Crypto.shared.identityForBackup() else { return nil }
        let myPk = Data(mine.pk).base64EncodedString()
        guard UserDefaults.standard.string(forKey: "keyBackup.checkedPk.\(uid)") != myPk else { return nil }
        guard let s = try? await status() else { return nil }   // offline: ask again next launch
        if !s.exists || s.pk == myPk || UserDefaults.standard.string(forKey: "keyBackup.skipped.\(uid)") == s.updatedAt {
            markChecked()
            return nil
        }
        return s
    }

    static func skip(_ s: Status) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        UserDefaults.standard.set(s.updatedAt, forKey: "keyBackup.skipped.\(uid)")
        markChecked()
    }

    /// Last known On/Off, so the Settings row has a word before the server answers.
    static var knownOn: Bool? {
        guard let uid = Auth.auth().currentUser?.uid,
              UserDefaults.standard.object(forKey: "keyBackup.on.\(uid)") != nil else { return nil }
        return UserDefaults.standard.bool(forKey: "keyBackup.on.\(uid)")
    }

    // MARK: - Private

    private static func rememberOn(_ on: Bool) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        UserDefaults.standard.set(on, forKey: "keyBackup.on.\(uid)")
    }

    private static func markChecked() {
        Task {
            guard let uid = Auth.auth().currentUser?.uid,
                  let mine = await Crypto.shared.identityForBackup() else { return }
            UserDefaults.standard.set(Data(mine.pk).base64EncodedString(), forKey: "keyBackup.checkedPk.\(uid)")
        }
    }

    /// Argon2id: 64 MiB and a few hundred ms, so never on the main thread.
    private static func derive(pin: String, salt: Bytes, ops: Int, mem: Int) async -> (lock: Bytes, auth: Bytes)? {
        await Task.detached(priority: .userInitiated) {
            guard let out = Sodium().pwHash.hash(outputLength: 64, passwd: Bytes(pin.utf8), salt: salt,
                                                 opsLimit: ops, memLimit: mem, alg: .Argon2ID13),
                  out.count == 64 else { return nil }
            return (Bytes(out[0..<32]), Bytes(out[32..<64]))
        }.value
    }

    private static func failure(from error: Error) -> Failure {
        let ns = error as NSError
        let details = ns.userInfo["details"] as? [String: Any] ?? [:]
        let until = (details["lockedUntil"] as? NSNumber)?.doubleValue ?? 0
        guard ns.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: ns.code) else {
            return .other(error.localizedDescription)
        }
        switch code {
        case .permissionDenied:
            if until > Date().timeIntervalSince1970 * 1000 { return .locked(until: Date(timeIntervalSince1970: until / 1000)) }
            if let n = (details["triesLeft"] as? NSNumber)?.intValue { return .wrong(triesLeft: n) }
            return .other("This phone can't use the backup yet. Finish signing in first.")
        case .resourceExhausted:
            return .locked(until: Date(timeIntervalSince1970: until / 1000))
        case .notFound:
            return .gone(wiped: details["wiped"] as? Bool ?? false)
        case .unavailable, .deadlineExceeded:
            return .other("No connection. Try again.")
        default:
            return .other(error.localizedDescription)
        }
    }
}
