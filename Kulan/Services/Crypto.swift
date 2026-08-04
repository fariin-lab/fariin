//  Crypto.swift
//  Fariin — native E2EE, wire-compatible with the React Native tweetnacl client.
//
//  This is a faithful Swift port of src/utils/crypto.ts. It uses libsodium
//  (via swift-sodium), whose crypto_box_easy / crypto_secretbox_easy are
//  byte-for-byte compatible with tweetnacl's nacl.box / nacl.secretbox:
//
//    nacl.box(msg, nonce, theirPub, mySecret)  ==  crypto_box_easy(msg, nonce, theirPub, mySecret)
//    nacl.secretbox(msg, nonce, key)           ==  crypto_secretbox_easy(msg, nonce, key)
//
//  Both produce: 24-byte nonce (separate) + (16-byte Poly1305 MAC ‖ ciphertext).
//  tweetnacl-util base64 is STANDARD, PADDED base64 — we use Foundation's
//  Data.base64EncodedString(), which matches exactly (do NOT use Sodium.Utils
//  base64, which defaults to a URL-safe / unpadded variant).
//
//  Wire format (identical to the RN client):
//    text  -> "enc1:<b64 nonce>:<b64 box>"
//    image -> ciphertext bytes in Storage + EncMeta { v:1, n, k, kn }
//
//  Dependencies (SPM):  https://github.com/jedisct1/swift-sodium  (product: "Sodium")
//                       Firebase (FirebaseFirestore, FirebaseAuth)

import Foundation
import Security
import Sodium
import FirebaseFirestore
import FirebaseAuth

/// Thrown when the recipient has not published a public key yet. Callers MUST
/// queue / halt — never fall back to sending plaintext (the "queue, don't leak" rule).
struct MissingRecipientKeyError: Error {
    let uid: String
}

/// Per-attachment envelope stored alongside an encrypted file. Mirrors EncMeta in crypto.ts.
struct EncMeta: Codable, Equatable, Hashable {
    let v: Int       // always 1
    let n: String    // b64 secretbox nonce (the file data)
    let k: String    // b64 file key, wrapped to the recipient with box (1:1)
    let kn: String   // b64 nonce used to wrap the file key (1:1)
    var w: [String: String]? = nil   // group: per-member wrapped file keys ("keyB64.nonceB64")
    var a: String? = nil             // group: author uid (whose key sealed the wraps)

    var asDict: [String: Any] {
        var d: [String: Any] = ["v": v, "n": n, "k": k, "kn": kn]
        if let w { d["w"] = w }
        if let a { d["a"] = a }
        return d
    }
}

final class Crypto {
    static let shared = Crypto()
    private init() {}

    private let sodium = Sodium()
    private let db = Firestore.firestore()
    // Legacy APP-SCOPED key names (one keypair per device, whoever was signed in). This path is
    // INERT since the 2026-08-03 rename: nothing has ever written a `fariin_` app-scoped key, so
    // the migration branch in initKeys() can no longer fire. Left in place rather than deleted
    // because it costs nothing and removing live crypto paths at 3am is how keys get lost.
    private static let legacySkKey = "fariin_secret_key_v1"
    private static let legacyPkKey = "fariin_public_key_v1"

    // PER-ACCOUNT keys. Scoping by uid is what makes sign-out safe: a different account simply
    // finds no entry and generates its own keypair, so we no longer have to DELETE keys on
    // sign-out — which used to make every past message permanently unreadable if you ever signed
    // back into the same account.
    private static func skKeychainKey(_ uid: String) -> String { "fariin_secret_key_v1.\(uid)" }
    private static func pkKeychainKey(_ uid: String) -> String { "fariin_public_key_v1.\(uid)" }

    // In-memory key state (set by ensureReady / preloadKey; read by the sync `decrypt`).
    private var myPublicKey: Bytes?
    private var mySecretKey: Bytes?
    private var pubCache: [String: Bytes] = [:]
    private let lock = NSLock()                 // guards pubCache for the sync decrypt path
    private var readyTask: Task<Void, Error>?
    private var didWarm = false                 // one-time synchronous warm on the first decrypt
    private static let pubKeysDefaultsKey = "crypto.pubKeys.v1"   // disk cache of others' PUBLIC keys (not secret)

    var isReady: Bool { mySecretKey != nil }

    private func currentUid() -> String? { Auth.auth().currentUser?.uid }

    // Persist a peer's PUBLIC key to disk (public keys are not secret) so decrypt works on the FIRST
    // render after a cold launch instead of showing "…" until the network fetch lands.
    private func persistPubKey(_ uid: String, _ key: Bytes) {
        var dict = (UserDefaults.standard.dictionary(forKey: Self.pubKeysDefaultsKey) as? [String: String]) ?? [:]
        let b64 = Data(key).base64EncodedString()
        guard dict[uid] != b64 else { return }
        dict[uid] = b64
        UserDefaults.standard.set(dict, forKey: Self.pubKeysDefaultsKey)
    }

    // One-time synchronous warm start, run lazily on the first decrypt (the chat-list render): load the
    // existing keypair from the Keychain and every peer's persisted public key from disk. No network, no
    // key generation — just enough to decrypt the last-message previews immediately (fixes the "…" flash
    // where the chat list rendered before the async initKeys + network key fetches completed).
    private func warmIfNeeded() {
        lock.withLock {
            guard !didWarm else { return }
            didWarm = true
            if let dict = UserDefaults.standard.dictionary(forKey: Self.pubKeysDefaultsKey) as? [String: String] {
                for (uid, b64) in dict where pubCache[uid] == nil {
                    if let d = Data(base64Encoded: b64) { pubCache[uid] = Bytes(d) }
                }
            }
            // Per-account keys: only load a key when we know WHOSE it is (loading blind could
            // hand one account another account's identity).
            if mySecretKey == nil, let uid = currentUid(),
               let skB64 = Keychain.get(Self.skKeychainKey(uid)) ?? Keychain.get(Self.legacySkKey),
               let pkB64 = Keychain.get(Self.pkKeychainKey(uid)) ?? Keychain.get(Self.legacyPkKey),
               let sk = Data(base64Encoded: skB64), let pk = Data(base64Encoded: pkB64),
               sk.count == sodium.box.SecretKeyBytes {
                mySecretKey = Bytes(sk); myPublicKey = Bytes(pk)
                pubCache[uid] = Bytes(pk)
            }
        }
    }

    // MARK: - Setup

    /// Generate/load this device's key pair and publish the public key. Idempotent.
    /// The readyTask check-and-set is ATOMIC (under `lock`) so concurrent first-launch callers
    /// (ConversationsRepository.start, ThreadRepository.start, key preloads) can't each spawn
    /// initKeys() and generate TWO different keypairs — which permanently loses messages
    /// encrypted with the discarded key.
    func ensureReady() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let t = readyTask { return t }
            let t = Task { try await self.initKeys() }   // Task{} only schedules; safe inside the lock
            readyTask = t
            return t
        }
        do { try await task.value }
        catch {
            // Only one task is ever created (atomic check-and-set above), so the failed one is the
            // current readyTask — clear it so the next ensureReady retries. (Task is a struct → no ===.)
            lock.withLock { readyTask = nil }
            throw error
        }
    }

    private func initKeys() async throws {
        guard let uid = currentUid() else {
            throw NSError(domain: "Crypto", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ensureReady() called before sign-in"])
        }

        // Load THIS ACCOUNT's keypair from the Keychain, or generate + persist a new one.
        let skBytes: Bytes, pkBytes: Bytes
        if let skB64 = Keychain.get(Self.skKeychainKey(uid)),
           let pkB64 = Keychain.get(Self.pkKeychainKey(uid)),
           let sk = Data(base64Encoded: skB64),
           let pk = Data(base64Encoded: pkB64),
           sk.count == sodium.box.SecretKeyBytes {
            skBytes = Bytes(sk)
            pkBytes = Bytes(pk)
        } else if let skB64 = Keychain.get(Self.legacySkKey),
                  let pkB64 = Keychain.get(Self.legacyPkKey),
                  let sk = Data(base64Encoded: skB64),
                  let pk = Data(base64Encoded: pkB64),
                  sk.count == sodium.box.SecretKeyBytes {
            // MIGRATION (one-time, existing installs): the device-wide key belongs to whoever is
            // signed in right now — that's this uid. Claim it into their per-account slot so their
            // history stays readable, then drop the legacy entry so no LATER account can adopt it.
            skBytes = Bytes(sk)
            pkBytes = Bytes(pk)
            Keychain.set(Self.skKeychainKey(uid), skB64)
            Keychain.set(Self.pkKeychainKey(uid), pkB64)
            Keychain.delete(Self.legacySkKey)
            Keychain.delete(Self.legacyPkKey)
        } else {
            guard let kp = sodium.box.keyPair() else {
                throw NSError(domain: "Crypto", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "key generation failed"])
            }
            skBytes = kp.secretKey
            pkBytes = kp.publicKey
            Keychain.set(Self.skKeychainKey(uid), Data(kp.secretKey).base64EncodedString())
            Keychain.set(Self.pkKeychainKey(uid), Data(kp.publicKey).base64EncodedString())
        }
        // Single lock-guarded write (memory barrier); the keypair is immutable after this.
        lock.withLock { mySecretKey = skBytes; myPublicKey = pkBytes; pubCache[uid] = pkBytes }

        // Publish my public key so others can encrypt to me. Fire-and-forget: the
        // keypair is already usable locally (set above), and blocking here made a
        // no-network cold start hang ~10s on the server timeout. publishPublicKey()
        // self-heals on every launch, so a lost publish is retried next open.
        let myPubB64 = Data(pkBytes).base64EncodedString()
        Task { await Self.publishKeyIfChanged(db: db, uid: uid, b64: myPubB64) }
    }

    private static func publishKeyIfChanged(db: Firestore, uid: String, b64: String) async {
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            if (snap.data()?["publicKey"] as? String) != b64 {
                try await db.collection("users").document(uid)
                    .setData(["publicKey": b64], merge: true)
            }
        } catch {
            print("crypto: publishing public key failed:", error)
        }
    }

    /// Re-publish my public key (idempotent, self-healing). Safe to call on every
    /// launch AFTER the profile doc exists — recovers accounts whose key publish
    /// failed earlier (e.g. the write lost a race with profile creation), which
    /// otherwise leaves them permanently unmessageable.
    func publishPublicKey() async {
        do { try await ensureReady() } catch { return }
        guard let uid = currentUid(), let pk = myPublicKey else { return }
        await Self.publishKeyIfChanged(db: db, uid: uid, b64: Data(pk).base64EncodedString())
    }

    /// Sign-out: forget the in-memory E2EE identity so the next account starts clean.
    ///
    /// The KEYCHAIN KEY IS DELIBERATELY KEPT. Keys are per-uid now, so the next account
    /// simply finds no entry of its own and generates a fresh keypair — which is what deleting
    /// used to accomplish. Deleting was also destroying history: signing out and back into the
    /// SAME account regenerated a keypair and republished it, leaving every earlier message
    /// permanently undecryptable. Keeping the key means sign-out is reversible, as users expect.
    ///
    /// The account's key IS removed on real account deletion — see `destroyIdentity(uid:)`.
    func wipeIdentity() {
        lock.withLock {
            mySecretKey = nil; myPublicKey = nil
            pubCache = [:]
            readyTask = nil
            didWarm = false
        }
        UserDefaults.standard.removeObject(forKey: Self.pubKeysDefaultsKey)   // cache of others' PUBLIC keys
    }

    /// Account DELETION: the account is gone for good, so its private key should go too
    /// (nothing is left to decrypt, and leaving it on the device is needless exposure).
    func destroyIdentity(uid: String) {
        Keychain.delete(Self.skKeychainKey(uid))
        Keychain.delete(Self.pkKeychainKey(uid))
        Keychain.delete(Self.legacySkKey)
        Keychain.delete(Self.legacyPkKey)
        wipeIdentity()
    }

    /// My identity public key (Curve25519), for the safety-number screen. nil until
    /// ensureReady() has run — callers should `try await ensureReady()` first.
    var myPublicKeyData: Data? { lock.withLock { myPublicKey.map { Data($0) } } }

    /// Another user's identity public key as Data (fetches + caches). nil if none yet.
    func publicKeyData(for uid: String) async -> Data? {
        (await preloadKey(uid)).map { Data($0) }
    }

    // In-flight fetch dedup (the standard profile-fetch pattern): on a cold start the chat list, the open thread,
    // and group-member warms all request the same keys SIMULTANEOUSLY — without dedup each fires its
    // own Firestore read. Concurrent callers now share one Task per uid.
    private var keyFetches: [String: Task<Bytes?, Never>] = [:]

    /// Fetch + cache another user's public key. Returns nil if they have none yet.
    @discardableResult
    func preloadKey(_ uid: String) async -> Bytes? {
        guard !uid.isEmpty else { return nil }
        if let cached = lock.withLock({ pubCache[uid] }) { return cached }
        let task: Task<Bytes?, Never> = lock.withLock {
            if let existing = keyFetches[uid] { return existing }
            let t = Task { await self.fetchKey(uid) }
            keyFetches[uid] = t
            return t
        }
        let result = await task.value
        lock.withLock { _ = keyFetches.removeValue(forKey: uid) }
        return result
    }

    /// KEY ROTATION RECOVERY (audit). Peer public keys were cached in memory AND on disk with no
    /// expiry, no listener and no refetch, so a contact who reinstalls or moves to a new phone
    /// (their per-device Keychain key does not migrate, so `initKeys` publishes a fresh pair) broke
    /// the chat PERMANENTLY in both directions: everything we sealed used their dead key, and
    /// everything they sent failed to open, showing the lock placeholder forever. Only signing out
    /// cleared it. A decrypt failure now drops the cached copy once and refetches, so the next
    /// render heals — at most one extra read per peer per rotation, and never a loop, because a
    /// genuinely undecryptable message keeps its placeholder after the refreshed key still fails.
    private var keyRefreshInFlight = Set<String>()
    func refreshKeyAfterFailure(_ uid: String) {
        guard !uid.isEmpty else { return }
        let start: Bool = lock.withLock {
            if keyRefreshInFlight.contains(uid) { return false }
            keyRefreshInFlight.insert(uid)
            return true
        }
        guard start else { return }
        Task {
            lock.withLock { pubCache.removeValue(forKey: uid) }
            // Drop the DISK copy too (same shared dictionary persistPubKey writes), or the next cold
            // launch would warm the dead key straight back into memory.
            var dict = (UserDefaults.standard.dictionary(forKey: Self.pubKeysDefaultsKey) as? [String: String]) ?? [:]
            if dict.removeValue(forKey: uid) != nil {
                UserDefaults.standard.set(dict, forKey: Self.pubKeysDefaultsKey)
            }
            _ = await fetchKey(uid)
            lock.withLock { _ = keyRefreshInFlight.remove(uid) }
        }
    }

    private func fetchKey(_ uid: String) async -> Bytes? {
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            if let b64 = snap.data()?["publicKey"] as? String,
               let data = Data(base64Encoded: b64) {
                let key = Bytes(data)
                lock.withLock { pubCache[uid] = key }
                persistPubKey(uid, key)   // disk cache → decrypt works on the next cold launch's first render
                return key
            }
        } catch {
            print("crypto: preloadKey failed:", error)
        }
        return nil
    }

    // MARK: - cid helpers (cid = "uidA_uidB")

    private func otherUid(_ cid: String) -> String {
        let me = currentUid() ?? ""
        let parts = cid.split(separator: "_").map(String.init)
        guard parts.count == 2 else { return "" }
        return parts[0] == me ? parts[1] : parts[0]
    }

    // MARK: - Text

    /// Encrypt plaintext for a conversation. Returns "enc1:<nonce>:<cipher>".
    /// NEVER returns plaintext; throws MissingRecipientKeyError if the recipient has no key.
    func encryptForConversation(_ cid: String, _ text: String) async throws -> String {
        try await ensureReady()
        guard let sk = mySecretKey else {
            throw NSError(domain: "Crypto", code: 3, userInfo: [NSLocalizedDescriptionKey: "keys not ready"])
        }
        let other = otherUid(cid)
        guard let otherPub = await preloadKey(other) else { throw MissingRecipientKeyError(uid: other) }

        // box.seal(...) -> (authenticatedCipherText = MAC‖ct, nonce) ; matches nacl.box output.
        guard let sealed: (authenticatedCipherText: Bytes, nonce: Box.Nonce) =
                sodium.box.seal(message: Bytes(text.utf8), recipientPublicKey: otherPub, senderSecretKey: sk) else {
            throw NSError(domain: "Crypto", code: 4, userInfo: [NSLocalizedDescriptionKey: "seal failed"])
        }
        let nonceB64 = Data(sealed.nonce).base64EncodedString()
        let boxB64 = Data(sealed.authenticatedCipherText).base64EncodedString()
        return "enc1:\(nonceB64):\(boxB64)"
    }

    /// True once my keys and the recipient's public key are both available.
    func recipientReady(_ cid: String) async -> Bool {
        do {
            try await ensureReady()
            return await preloadKey(otherUid(cid)) != nil
        } catch { return false }
    }

    /// Decrypt a stored value SYNCHRONOUSLY (keys must already be cached via
    /// ensureReady + preloadKey). Mirrors crypto.ts `decrypt`:
    ///   - not "enc1:"           -> returned as-is (plaintext / preview)
    ///   - "enc:" (legacy fake)  -> "[old message]"
    ///   - keys not ready        -> "…"
    ///   - tampered / wrong key  -> "🔒"
    func decrypt(_ raw: String, cid: String) -> String {
        if raw.hasPrefix("enc:") { return "[old message]" }
        guard raw.hasPrefix("enc1:") else { return raw }
        warmIfNeeded()
        guard let sk = mySecretKey else { return "…" }
        guard let otherPub = lock.withLock({ pubCache[otherUid(cid)] }) else { return "…" }

        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let nonce = Data(base64Encoded: parts[1]),
              let box = Data(base64Encoded: parts[2]) else { return "🔒" }

        guard let opened = sodium.box.open(authenticatedCipherText: Bytes(box),
                                           senderPublicKey: otherPub,
                                           recipientSecretKey: sk,
                                           nonce: Bytes(nonce)),
              let text = String(bytes: opened, encoding: .utf8) else {
            // Most likely their key rotated (new phone / reinstall) and ours is stale — refetch once
            // so the next render heals instead of showing this lock forever. See refreshKeyAfterFailure.
            refreshKeyAfterFailure(otherUid(cid))
            return "🔒"
        }
        return text
    }

    // Memoized decrypt for hot, repeatedly-rendered text — the chat-list last-message
    // preview decrypts on EVERY row render/scroll. The same (cid, raw) always yields the
    // same plaintext, so caching it avoids re-running libsodium box.open per frame (a
    // real scroll-smoothness win, the standard "decrypt once, reuse"). NSCache is
    // thread-safe and self-evicting under memory pressure.
    private let previewCache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 500   // bounded (cap every hot cache) — plaintext previews are small but not free
        return c
    }()
    func decryptCached(_ raw: String, cid: String) -> String {
        let key = "\(cid)|\(raw)" as NSString
        if let hit = previewCache.object(forKey: key) { return hit as String }
        let out = decrypt(raw, cid: cid)
        // Don't memoize failure sentinels — the recipient's key may just not be warm yet.
        // Caching "…"/"🔒" would freeze the chat-list preview until a new message arrives.
        if out != "…" && out != "🔒" { previewCache.setObject(out as NSString, forKey: key) }
        return out
    }

    // Cached GROUP preview decrypt: the 3-arg decrypt routes group ciphers through decryptGroup
    // (base64 + JSON + sodium), which is expensive to run on the main thread per render. Memoize
    // it (the cid|author|cipher tuple is stable) so chat-list/peek group previews don't re-decrypt.
    func decryptGroupCached(_ raw: String, cid: String, authorId: String) -> String {
        let key = "g|\(cid)|\(authorId)|\(raw)" as NSString
        if let hit = previewCache.object(forKey: key) { return hit as String }
        let out = decrypt(raw, cid: cid, authorId: authorId)
        if out != "…" && out != "🔒" { previewCache.setObject(out as NSString, forKey: key) }
        return out
    }

    // MARK: - Files / images

    /// Encrypt raw file bytes. The file is sealed with a fresh secretbox key; that
    /// key is wrapped to the recipient with box. Mirrors crypto.ts `encryptBytes`.
    func encryptBytes(_ cid: String, _ data: Data) async throws -> (cipher: Data, meta: EncMeta) {
        try await ensureReady()
        guard let sk = mySecretKey else {
            throw NSError(domain: "Crypto", code: 5, userInfo: [NSLocalizedDescriptionKey: "keys not ready"])
        }
        let other = otherUid(cid)
        guard let otherPub = await preloadKey(other) else { throw MissingRecipientKeyError(uid: other) }

        let fileKey = sodium.secretBox.key()                       // random 32-byte key
        guard let sealedFile: (authenticatedCipherText: Bytes, nonce: SecretBox.Nonce) =
                sodium.secretBox.seal(message: Bytes(data), secretKey: fileKey) else {
            throw NSError(domain: "Crypto", code: 6, userInfo: [NSLocalizedDescriptionKey: "secretbox seal failed"])
        }
        guard let wrapped: (authenticatedCipherText: Bytes, nonce: Box.Nonce) =
                sodium.box.seal(message: fileKey, recipientPublicKey: otherPub, senderSecretKey: sk) else {
            throw NSError(domain: "Crypto", code: 7, userInfo: [NSLocalizedDescriptionKey: "key wrap failed"])
        }

        let meta = EncMeta(
            v: 1,
            n: Data(sealedFile.nonce).base64EncodedString(),
            k: Data(wrapped.authenticatedCipherText).base64EncodedString(),
            kn: Data(wrapped.nonce).base64EncodedString()
        )
        return (Data(sealedFile.authenticatedCipherText), meta)
    }

    /// Group file encryption: seal the file once under a random key, then wrap that key for
    /// EVERY member (incl. the author). Same shape as encryptForGroup but for media. The
    /// per-member wraps + author go into EncMeta.w / EncMeta.a so decryption self-routes.
    func encryptBytesForGroup(_ data: Data, members: [String]) async throws -> (cipher: Data, meta: EncMeta) {
        try await ensureReady()
        guard let sk = mySecretKey, let me = currentUid() else {
            throw NSError(domain: "Crypto", code: 11, userInfo: [NSLocalizedDescriptionKey: "keys not ready"])
        }
        let fileKey = sodium.secretBox.key()
        guard let sealedFile: (authenticatedCipherText: Bytes, nonce: SecretBox.Nonce) =
                sodium.secretBox.seal(message: Bytes(data), secretKey: fileKey) else {
            throw NSError(domain: "Crypto", code: 12, userInfo: [NSLocalizedDescriptionKey: "group file seal failed"])
        }
        var wraps: [String: String] = [:]
        for uid in Set(members) {
            guard let pub = await preloadKey(uid) else { continue }   // skip keyless members
            guard let w: (authenticatedCipherText: Bytes, nonce: Box.Nonce) =
                    sodium.box.seal(message: fileKey, recipientPublicKey: pub, senderSecretKey: sk) else { continue }
            wraps[uid] = Data(w.authenticatedCipherText).base64EncodedString()
                       + "." + Data(w.nonce).base64EncodedString()
        }
        guard wraps.keys.contains(where: { $0 != me }) else {
            throw MissingRecipientKeyError(uid: members.first { $0 != me } ?? "")
        }
        let meta = EncMeta(v: 1, n: Data(sealedFile.nonce).base64EncodedString(), k: "", kn: "", w: wraps, a: me)
        return (Data(sealedFile.authenticatedCipherText), meta)
    }

    /// Reverse of encryptBytes. Returns nil if keys are missing or auth fails.
    func decryptBytes(_ cid: String, cipher: Data, meta: EncMeta) async -> Data? {
        // Group media (meta.w present): unwrap MY copy of the file key with the AUTHOR's key.
        if let wraps = meta.w, let author = meta.a {
            do { try await ensureReady(); _ = await preloadKey(author) } catch {}
            guard let sk = mySecretKey, let me = currentUid(),
                  let myWrap = wraps[me],
                  let authorPub = lock.withLock({ pubCache[author] }) else { return nil }
            let wp = myWrap.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard wp.count == 2,
                  let wrappedKey = Data(base64Encoded: wp[0]),
                  let keyNonce = Data(base64Encoded: wp[1]),
                  let dataNonce = Data(base64Encoded: meta.n) else { return nil }
            guard let fileKey = sodium.box.open(authenticatedCipherText: Bytes(wrappedKey),
                                                senderPublicKey: authorPub, recipientSecretKey: sk,
                                                nonce: Bytes(keyNonce)) else { return nil }
            guard let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(cipher),
                                                     secretKey: fileKey, nonce: Bytes(dataNonce)) else { return nil }
            return Data(opened)
        }
        do {
            try await ensureReady()
            _ = await preloadKey(otherUid(cid))
        } catch { /* checks below return nil if not ready */ }

        guard let sk = mySecretKey, meta.v == 1 else { return nil }
        guard let otherPub = lock.withLock({ pubCache[otherUid(cid)] }) else { return nil }
        guard let wrappedKey = Data(base64Encoded: meta.k),
              let keyNonce = Data(base64Encoded: meta.kn),
              let dataNonce = Data(base64Encoded: meta.n) else { return nil }

        guard let fileKey = sodium.box.open(authenticatedCipherText: Bytes(wrappedKey),
                                            senderPublicKey: otherPub,
                                            recipientSecretKey: sk,
                                            nonce: Bytes(keyNonce)) else {
            // Same key-rotation recovery the text path uses: a wrap that will not open is the
            // signature of a stale peer key, so drop it and refetch for the next attempt.
            refreshKeyAfterFailure(otherUid(cid))
            return nil
        }
        guard let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(cipher),
                                                 secretKey: fileKey,
                                                 nonce: Bytes(dataNonce)) else { return nil }
        return Data(opened)
    }

    // MARK: - Group text (sender-key-per-message)
    //
    // Generalizes the file-wrap pattern to N members: the body is sealed ONCE under a
    // random message key, and that key is wrapped to EVERY member's public key (including
    // the author, so the author can read their own message back on reload / another device).
    // Each member opens their own wrap with the AUTHOR's public key — NaCl box's DH secret
    // is symmetric, so author↔member both derive the same key. Wire format:
    //   "encg1:" + base64( JSON{ n: dataNonce, c: ciphertext, w: { uid: "wrapB64.nonceB64" } } )

    /// Encrypt text for a group. `members` should be the full member list (self included).
    /// Throws MissingRecipientKeyError if any member has no published key (never leaks plaintext).
    func encryptForGroup(_ text: String, members: [String]) async throws -> String {
        try await ensureReady()
        guard let sk = mySecretKey else {
            throw NSError(domain: "Crypto", code: 8, userInfo: [NSLocalizedDescriptionKey: "keys not ready"])
        }
        let msgKey = sodium.secretBox.key()
        guard let sealed: (authenticatedCipherText: Bytes, nonce: SecretBox.Nonce) =
                sodium.secretBox.seal(message: Bytes(text.utf8), secretKey: msgKey) else {
            throw NSError(domain: "Crypto", code: 9, userInfo: [NSLocalizedDescriptionKey: "group seal failed"])
        }
        let me = currentUid() ?? ""
        var wraps: [String: String] = [:]
        for uid in Set(members) {
            // Skip members who haven't published a key yet — they'll see "…" until they do.
            // One keyless member must NOT block the whole group (unlike a 1:1 chat).
            guard let pub = await preloadKey(uid) else { continue }
            guard let w: (authenticatedCipherText: Bytes, nonce: Box.Nonce) =
                    sodium.box.seal(message: msgKey, recipientPublicKey: pub, senderSecretKey: sk) else { continue }
            wraps[uid] = Data(w.authenticatedCipherText).base64EncodedString()
                       + "." + Data(w.nonce).base64EncodedString()
        }
        // Need at least one recipient besides me; otherwise there's no one to deliver to
        // (queue, like 1:1, rather than sending into the void).
        guard wraps.keys.contains(where: { $0 != me }) else {
            throw MissingRecipientKeyError(uid: members.first { $0 != me } ?? "")
        }
        let payload: [String: Any] = [
            "n": Data(sealed.nonce).base64EncodedString(),
            "c": Data(sealed.authenticatedCipherText).base64EncodedString(),
            "w": wraps,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        return "encg1:" + json.base64EncodedString()
    }

    /// Decrypt a group message. Needs the AUTHOR's uid (sender pubkey) — opens my own wrap.
    func decryptGroup(_ raw: String, authorId: String) -> String {
        guard raw.hasPrefix("encg1:") else { return raw }
        warmIfNeeded()
        guard let sk = mySecretKey, let me = currentUid() else { return "…" }
        guard let authorPub = lock.withLock({ pubCache[authorId] }) else { return "…" }
        let b64 = String(raw.dropFirst("encg1:".count))
        guard let jsonData = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let nB64 = obj["n"] as? String, let cB64 = obj["c"] as? String,
              let wraps = obj["w"] as? [String: String],
              let myWrap = wraps[me],
              let dataNonce = Data(base64Encoded: nB64),
              let ct = Data(base64Encoded: cB64) else { return "🔒" }
        let wp = myWrap.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard wp.count == 2,
              let wrappedKey = Data(base64Encoded: wp[0]),
              let keyNonce = Data(base64Encoded: wp[1]) else { return "🔒" }
        guard let msgKey = sodium.box.open(authenticatedCipherText: Bytes(wrappedKey),
                                           senderPublicKey: authorPub, recipientSecretKey: sk,
                                           nonce: Bytes(keyNonce)) else { return "🔒" }
        guard let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(ct),
                                                 secretKey: msgKey, nonce: Bytes(dataNonce)),
              let text = String(bytes: opened, encoding: .utf8) else { return "🔒" }
        return text
    }

    /// Routing decrypt: group envelopes need the author's key; 1:1 uses the cid pair.
    func decrypt(_ raw: String, cid: String, authorId: String) -> String {
        if raw.hasPrefix("encg1:") { return decryptGroup(raw, authorId: authorId) }
        return decrypt(raw, cid: cid)
    }
}

// MARK: - Minimal Keychain (replaces expo-secure-store)

enum Keychain {
    private static let service = "com.fariin.messenger.crypto"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // Available after first unlock; survives reboot, stays on this device only.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
