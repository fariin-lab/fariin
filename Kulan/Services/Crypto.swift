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

    /// 2026-10-19 groups v2 (owner): a file stored IN THE CLEAR, in a group that is no longer
    /// end-to-end encrypted. `v: 0` and no keys; `decryptBytes` hands such bytes back unchanged, so
    /// every reader of `enc` keeps working without knowing which kind it got. Never used in a 1:1.
    static let plain = EncMeta(v: 0, n: "", k: "", kn: "")
    var isPlain: Bool { v == 0 }
}

final class Crypto {
    static let shared = Crypto()
    private init() {}

    private let sodium = Sodium()
    private var db: Firestore { FirestoreHub.db }
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
    /// ⛔ EARLIER PUBLIC KEYS, PER PERSON — owner 2026-10-15: "messages I sent show a lock after I
    /// switched accounts". A message is sealed between two keypairs. When one side's published key is
    /// later REPLACED (the account signed in on a phone that did not hold its private key, which makes
    /// and publishes a new one), every message sealed with the old key failed here, the sender's own
    /// copies included, because decrypting asked only for the person's CURRENT key, and the old one
    /// was overwritten in `pubKeysDefaultsKey`. The old public key is still the right key for those
    /// messages. So every key a person has had is kept (here, newest first, 8 at most, and on their
    /// profile as `publicKeyHistory`), and a message that will not open with the current key is tried
    /// with the earlier ones before the lock is drawn. Public keys only: nothing secret is stored, and
    /// box.open still authenticates every message against a key of THAT person.
    private static let pubRingDefaultsKey = "crypto.pubRing.v1"

    /// Earlier public keys of `uid` this phone knows, newest first.
    private func earlierKeys(_ uid: String) -> [Bytes] {
        let ring = UserDefaults.standard.dictionary(forKey: Self.pubRingDefaultsKey) as? [String: [String]] ?? [:]
        return (ring[uid] ?? []).compactMap { Data(base64Encoded: $0).map { Bytes($0) } }
    }

    /// Adds keys (base64) to `uid`'s ring, newest first, 8 at most.
    private func rememberKeys(_ uid: String, _ b64s: [String]) {
        guard !uid.isEmpty, !b64s.isEmpty else { return }
        var ring = UserDefaults.standard.dictionary(forKey: Self.pubRingDefaultsKey) as? [String: [String]] ?? [:]
        var list = ring[uid] ?? []
        for b in b64s where !b.isEmpty && !list.contains(b) { list.insert(b, at: 0) }
        guard list != (ring[uid] ?? []) else { return }
        ring[uid] = Array(list.prefix(8))
        UserDefaults.standard.set(ring, forKey: Self.pubRingDefaultsKey)
        NotifShare.mirrorRing(ring)   // owner 2026-10-18 readable banners, see persistPubKey
    }

    /// box.open against `uid`'s current key, then their earlier ones (see `pubRingDefaultsKey`).
    private func openFrom(_ uid: String, current: Bytes, box: Bytes, nonce: Bytes, sk: Bytes) -> Bytes? {
        if let o = sodium.box.open(authenticatedCipherText: box, senderPublicKey: current,
                                   recipientSecretKey: sk, nonce: nonce) { return o }
        for old in earlierKeys(uid) where old != current {
            if let o = sodium.box.open(authenticatedCipherText: box, senderPublicKey: old,
                                       recipientSecretKey: sk, nonce: nonce) {
                recheckKeyAfterOldOpen(uid)
                return o
            }
        }
        return nil
    }

    // ⛔ OPENED ONLY WITH AN OLD KEY: ASK THE SERVER AGAIN (owner 2026-10-30: his calls stuck on
    // "Connecting…"). His account's key moved to another device and back; the other phone kept the
    // stray key as his CURRENT one. Everything he sent still opened (with an earlier key from the
    // ring), so nothing ever failed on that phone and nothing refetched, but everything it SEALED to
    // him (the call answer, its network routes, messages) went to the stray key and his phone could
    // not open it. A message that opens only with an earlier key means my current key for the sender
    // may be stale: refetch it from the server, at most once in five minutes per person (old
    // messages legitimately open with old keys all the time).
    private var lastOldOpenRecheck: [String: Date] = [:]   // guarded by `lock`
    private func recheckKeyAfterOldOpen(_ uid: String) {
        let due: Bool = lock.withLock {
            if let t = lastOldOpenRecheck[uid], Date().timeIntervalSince(t) < 300 { return false }
            lastOldOpenRecheck[uid] = Date()
            return true
        }
        if due { refreshKeyAfterFailure(uid) }
    }

    var isReady: Bool { mySecretKey != nil }

    private func currentUid() -> String? { Auth.auth().currentUser?.uid }

    // Persist a peer's PUBLIC key to disk (public keys are not secret) so decrypt works on the FIRST
    // render after a cold launch instead of showing "…" until the network fetch lands.
    private func persistPubKey(_ uid: String, _ key: Bytes) {
        var dict = (UserDefaults.standard.dictionary(forKey: Self.pubKeysDefaultsKey) as? [String: String]) ?? [:]
        let b64 = Data(key).base64EncodedString()
        guard dict[uid] != b64 else { return }
        // The key being replaced still opens everything sealed with it: keep it (and the new one).
        rememberKeys(uid, [dict[uid], b64].compactMap { $0 })
        dict[uid] = b64
        UserDefaults.standard.set(dict, forKey: Self.pubKeysDefaultsKey)
        // owner 2026-10-18 readable banners: the notification extension opens a message with the
        // SENDER's public key, so it needs the same cache (Kulan/Services/NotifShare.swift).
        NotifShare.mirrorPubKeys(dict)
    }

    // One-time synchronous warm start, run lazily on the first decrypt (the chat-list render): load the
    // existing keypair from the Keychain and every peer's persisted public key from disk. No network, no
    // key generation — just enough to decrypt the last-message previews immediately (fixes the "…" flash
    // where the chat list rendered before the async initKeys + network key fetches completed).
    private func warmIfNeeded() {
        lock.withLock {
            guard !didWarm else { return }
            // ⛔ NOT WHILE SIGNED OUT — owner, 2026-09-26: "logout then login again, I lose my
            // messages; the chat list shows only …". Sign-out resets this flag, but the chat list is
            // still on screen for a moment and decrypts once more with nobody signed in. That call
            // found no uid, loaded nothing, and still marked the warm-up done, so after signing back
            // in the Keychain key was never read synchronously again and every preview drew the
            // "keys not ready" marker. Only a warm-up that knew WHOSE key to load counts.
            guard currentUid() != nil else { return }
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
            // ⛔ IF THE PRIVATE HALF DID NOT REACH THE KEYCHAIN, DO NOT PUBLISH THE PUBLIC ONE.
            //
            // A discarded result here meant a refused write still advertised the key: the session
            // worked, and the next launch found nothing, generated a SECOND keypair, republished,
            // and everything anyone had sealed to the first became permanently unreadable — showing
            // as a lock glyph with nothing to explain it. Failing the whole init instead means the
            // next launch simply tries again with nothing published in between.
            let storedSk = Keychain.set(Self.skKeychainKey(uid), Data(kp.secretKey).base64EncodedString())
            let storedPk = Keychain.set(Self.pkKeychainKey(uid), Data(kp.publicKey).base64EncodedString())
            guard storedSk, storedPk else {
                Keychain.delete(Self.skKeychainKey(uid))
                Keychain.delete(Self.pkKeychainKey(uid))
                throw NSError(domain: "Crypto", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "identity key could not be stored"])
            }
        }
        // Single lock-guarded write (memory barrier); the keypair is immutable after this.
        lock.withLock { mySecretKey = skBytes; myPublicKey = pkBytes; pubCache[uid] = pkBytes }
        // ⛔ READABLE BANNERS — owner 2026-10-18: a COPY of the secret key for the notification
        // extension, in the App Group's keychain group (Shared/NotifShared.swift), plus the peer key
        // caches it opens messages with. The private item above is untouched and stays the original.
        // Written on every identity load, so an install that already had its key gets the copy on
        // the first launch of this build. Removed by `wipeIdentity` (sign-out) and account deletion.
        NotifShare.storeIdentity(uid: uid, secretKeyB64: Data(skBytes).base64EncodedString())
        if let dict = UserDefaults.standard.dictionary(forKey: Self.pubKeysDefaultsKey) as? [String: String] {
            NotifShare.mirrorPubKeys(dict)
        }
        if let ring = UserDefaults.standard.dictionary(forKey: Self.pubRingDefaultsKey) as? [String: [String]] {
            NotifShare.mirrorRing(ring)
        }
        // Say so. Anything drawn before this with "…" (no key yet) can redraw now; the chat list
        // only healed when a PEER's key was fetched, so a list whose peers were already warm stayed
        // on "…" until the next message arrived.
        DispatchQueue.main.async { NotificationCenter.default.post(name: .cryptoIdentityReady, object: nil) }

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
            let published = snap.data()?["publicKey"] as? String
            if published != b64 {
                // ⛔ NOT FROM A PHONE A NEWER SIGN-IN REPLACED (owner 2026-10-30, one phone per
                // account). A phone signed out while it was closed runs this at its next launch,
                // before DeviceRegistry notices its record is gone, and would take the account's key
                // back from the phone now in use. This install registered before (the marker) and
                // its record is gone on the server: it is on its way out, so it publishes nothing.
                let device = DeviceRegistry.thisDeviceId
                if !device.isEmpty, UserDefaults.standard.bool(forKey: "device.registered.\(uid)"),
                   let rec = try? await db.collection("users").document(uid).collection("devices")
                       .document(device).getDocument(source: .server),
                   !rec.exists {
                    return
                }
                // The key it replaces goes into `publicKeyHistory`, with this one, so a phone that
                // never saw the old key can still open messages sealed with it (`pubRingDefaultsKey`).
                let keep = [published, b64].compactMap { $0 }
                try await db.collection("users").document(uid)
                    .setData(["publicKey": b64, "publicKeyHistory": FieldValue.arrayUnion(keep)], merge: true)
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
        // ⛔ AND THE DECRYPTED PREVIEWS. `previewCache` holds up to 500 plaintext message texts in a
        // process-lifetime singleton, and nothing cleared it — so after sign-out the previous
        // account's messages stayed readable in memory for the life of the process.
        //
        // Its group key is also built only from values every member shares (conversation, author,
        // ciphertext), so a second account on the same phone could take a cache hit for a message its
        // own keys cannot open. Emptying it with the identity closes both.
        previewCache.removeAllObjects()
        // owner 2026-10-18 readable banners: the extension's copy of the key goes with the identity,
        // so a signed-out phone shows "New message" again, never text. Sign-in writes it back.
        NotifShare.clearAccount()
        // ⛔ THE OTHERS' PUBLIC KEYS STAY ON DISK — owner, 2026-09-26, second report after the
        // sign-in fix: "after I log in again the chat list shows … and the text appears after
        // seconds". That wait was this line: every peer's key had to be fetched from the server
        // again before a single preview could decrypt, and the list only redraws once those
        // fetches land. They are PUBLIC keys, the same fact for whoever is signed in, so nothing
        // about them belongs to the account that left; a rotated key is still caught by
        // `refreshKeyAfterFailure`. The reference apps keep their local store across a sign-out for
        // the same reason: the list must read on its first frame. (`pubCache` in memory is cleared
        // above and refilled from this dictionary by `warmIfNeeded`.)
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
    /// Is this peer's public key already in memory? Synchronous and lock-guarded, so a caller can
    /// tell a cache hit from a real fetch without awaiting one — see the chat list's key warm, which
    /// republishes only when something was actually fetched.
    func hasCachedKey(_ uid: String) -> Bool {
        guard !uid.isEmpty else { return false }
        return lock.withLock { pubCache[uid] != nil }
    }

    func preloadKey(_ uid: String) async -> Bytes? {
        guard !uid.isEmpty else { return nil }
        if let cached = lock.withLock({ pubCache[uid] }) { return cached }
        let task: Task<Bytes?, Never> = lock.withLock {
            if let existing = keyFetches[uid] { return existing }
            let t = Task { await self.fetchKey(uid) }
            keyFetches[uid] = t
            return t
        }
        // Owner, 2026-10-08: a hung key read used to hold every send and call that needed this key
        // for ever. Wait at most 10s; on a timeout this caller gets nil (the send/call fails and can be
        // retried), the fetch entry is cleared so the next caller starts a fresh read, and the
        // recovery net hears about the stall. The hung read, if it ever lands, still fills the cache.
        let result = await Self.raceTimeout(10, task)
        lock.withLock { _ = keyFetches.removeValue(forKey: uid) }
        return result
    }

    /// First of "the fetch finished" and "`seconds` passed". A continuation, not a task group: a group
    /// would wait for the hung child on exit and defeat the point.
    private static func raceTimeout(_ seconds: Double, _ task: Task<Bytes?, Never>) async -> Bytes? {
        await withCheckedContinuation { (c: CheckedContinuation<Bytes?, Never>) in
            let once = OnceFlag()
            Task {
                let v = await task.value
                if once.claim() { c.resume(returning: v) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    print("[Recovery] key fetch timed out after \(Int(seconds))s")
                    await MainActor.run { SessionRecovery.noteStall("key") }
                    c.resume(returning: nil)
                }
            }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
    }

    /// 2026-09-24 fix-all #118: every member's key for a group seal, looked up in parallel with at
    /// most 8 reads in flight. The seal awaited `preloadKey` one member at a time, so a cold cache
    /// in a 30-member group was 30 round trips in a row before the message could leave. Cache hits
    /// return at once; concurrent callers still share one fetch per uid (`keyFetches`).
    func preloadKeys(_ uids: [String]) async -> [String: Bytes] {
        let unique = Array(Set(uids.filter { !$0.isEmpty }))
        var out: [String: Bytes] = [:]
        await withTaskGroup(of: (String, Bytes?).self) { group in
            var next = 0
            let width = 8
            while next < unique.count && next < width {
                let uid = unique[next]; next += 1
                group.addTask { (uid, await self.preloadKey(uid)) }
            }
            while let (uid, key) = await group.next() {
                if let key { out[uid] = key }
                if next < unique.count {
                    let u = unique[next]; next += 1
                    group.addTask { (u, await self.preloadKey(u)) }
                }
            }
        }
        return out
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
    /// 2026-09-24 fix-all #70: items (uid + the ciphertext's nonce) that have already paid for one
    /// refetch this session. A message sealed to a peer's OLD key never opens again, and every new
    /// snapshot (each chat reopen) rebuilt it and fired another `users/{uid}` read and disk rewrite.
    /// The first failure of an item still refetches (that is how a rotation heals); a repeat of the
    /// same item is known-unreadable and is left alone until the app restarts.
    private var refreshedItems = Set<String>()
    func refreshKeyAfterFailure(_ uid: String, item: String? = nil) {
        guard !uid.isEmpty else { return }
        if let item {
            let first: Bool = lock.withLock {
                if refreshedItems.count > 5000 { refreshedItems.removeAll() }   // bounded
                return refreshedItems.insert(uid + "|" + item).inserted
            }
            guard first else { return }
        }
        let start: Bool = lock.withLock {
            if keyRefreshInFlight.contains(uid) { return false }
            keyRefreshInFlight.insert(uid)
            return true
        }
        guard start else { return }
        Task {
            // Owner, 2026-10-08: FETCH FIRST, replace after. This used to delete the good key (memory
            // and disk) before asking the server, so a refused or offline fetch left the person with
            // no key at all: their messages showed "..." and sends and calls to them failed until a
            // later fetch worked. Now the old key stays until the server answers: a key replaces it,
            // a clear "no key" removes it, an error keeps it.
            switch await fetchKeyResult(uid, source: .server) {
            case .key(let b):
                _ = b   // adoptKey already replaced memory and disk
            case .noKey:
                lock.withLock { _ = pubCache.removeValue(forKey: uid) }
                // The DISK copy too (same shared dictionary persistPubKey writes), or the next cold
                // launch would warm the dead key straight back into memory.
                var dict = (UserDefaults.standard.dictionary(forKey: Self.pubKeysDefaultsKey) as? [String: String]) ?? [:]
                if dict.removeValue(forKey: uid) != nil {
                    UserDefaults.standard.set(dict, forKey: Self.pubKeysDefaultsKey)
                    NotifShare.mirrorPubKeys(dict)   // owner 2026-10-18 readable banners
                }
            case .failed:
                break   // keep the old key; fetchKeyResult already told the recovery net
            }
            lock.withLock { _ = keyRefreshInFlight.remove(uid) }
        }
    }

    /// 2026-09-24 fix-all #212: the safety-number page must show the key the SERVER holds now, not
    /// whatever was cached when the chat last failed a decrypt. A server-only read, so offline is a
    /// thrown error the page can name instead of a silent stale number. On success the key goes
    /// through the same cache + change log as every other fetch (`fetchKey`).
    enum FreshKey { case key(Bytes), noKey, unreachable }
    func fetchFreshKey(_ uid: String) async -> FreshKey {
        guard !uid.isEmpty else { return .noKey }
        do {
            let snap = try await db.collection("users").document(uid).getDocument(source: .server)
            guard let b64 = snap.data()?["publicKey"] as? String,
                  let data = Data(base64Encoded: b64) else { return .noKey }
            return .key(adoptKey(uid, data))
        } catch {
            return .unreachable
        }
    }

    private enum KeyFetch { case key(Bytes), noKey, failed }

    /// One read of `users/{uid}` told apart three ways. "No key" is only believed when it came from
    /// the server; an empty answer from the local copy counts as failed so it can never remove a key.
    private func fetchKeyResult(_ uid: String, source: FirestoreSource = .default) async -> KeyFetch {
        do {
            let snap = try await db.collection("users").document(uid).getDocument(source: source)
            if let history = snap.data()?["publicKeyHistory"] as? [String] { rememberKeys(uid, history.reversed()) }
            if let b64 = snap.data()?["publicKey"] as? String,
               let data = Data(base64Encoded: b64) {
                return .key(adoptKey(uid, data))
            }
            return snap.metadata.isFromCache ? .failed : .noKey
        } catch {
            print("[Recovery] crypto: key fetch failed:", error)
            await MainActor.run { SessionRecovery.noteRefusal(error, "key") }
            return .failed
        }
    }

    private func fetchKey(_ uid: String) async -> Bytes? {
        if case .key(let b) = await fetchKeyResult(uid) { return b }
        return nil
    }

    /// Every fetched peer key enters the app here (split out of `fetchKey` 2026-09-24 fix-all #212 so
    /// the server-only read shares it).
    private func adoptKey(_ uid: String, _ data: Data) -> Bytes {
        let key = Bytes(data)
        lock.withLock { pubCache[uid] = key }
        persistPubKey(uid, key)   // disk cache → decrypt works on the next cold launch's first render
        // AND SAY SO WHEN IT IS A DIFFERENT KEY THAN LAST TIME. This is the one place every
        // peer key enters the app, so it is the only place that can notice. See SafetyKeyLog:
        // the working caches above are cleared on purpose when a decrypt fails, so they can
        // never answer "what did we use to see?" — the log is separate for exactly that.
        if SafetyKeyLog.note(uid: uid, key: data) {
            NotificationCenter.default.post(name: .peerKeyChanged, object: uid)
        }
        return key
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

    /// The same seal as `encryptForConversation` (same "enc1:" format, so `decrypt` opens it), but
    /// SYNCHRONOUS and from keys already in memory or on disk only: nil means "not ready", never a
    /// network wait. Owner audit 2026-10-06 #27: call signalling is sealed inside WebRTC completions
    /// whose ordering is timing-critical (held pre-answer, candidate buffer), where an await would
    /// reorder writes. The caller prefetches the peer key at dial / ring time so this normally hits.
    func encryptForConversationIfCached(_ cid: String, _ text: String) -> String? {
        warmIfNeeded()
        guard let sk = lock.withLock({ mySecretKey }),
              let otherPub = lock.withLock({ pubCache[otherUid(cid)] }) else { return nil }
        guard let sealed: (authenticatedCipherText: Bytes, nonce: Box.Nonce) =
                sodium.box.seal(message: Bytes(text.utf8), recipientPublicKey: otherPub, senderSecretKey: sk) else {
            return nil
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

        guard let opened = openFrom(otherUid(cid), current: otherPub, box: Bytes(box), nonce: Bytes(nonce), sk: sk),
              let text = String(bytes: opened, encoding: .utf8) else {
            // Most likely their key rotated (new phone / reinstall) and ours is stale — refetch once
            // so the next render heals instead of showing this lock forever. See refreshKeyAfterFailure.
            // Keyed by this message's nonce (2026-09-24 fix-all #70): once per message per session.
            refreshKeyAfterFailure(otherUid(cid), item: parts[1])
            Telemetry.event(.warning, component: "crypto", code: "decrypt_text_failed")   // owner 2026-10-21
            return "🔒"
        }
        return text
    }

    /// A LIVE call signal (offer, answer, network route): as `decrypt`, and when it opens only with
    /// an earlier key of the sender, that key becomes their current one at once (owner 2026-10-30,
    /// calls stuck on "Connecting…"). A signal of a call ringing now can only come from the device
    /// the sender is using now, so the key that opened it is the one to seal back to; the answer
    /// and routes are sealed within half a second of the ring, before any server read could land.
    /// Old messages never do this (they open with old keys by right): only call signalling calls it.
    func decryptLive(_ raw: String, cid: String) -> String {
        guard raw.hasPrefix("enc1:") else { return decrypt(raw, cid: cid) }
        warmIfNeeded()
        let uid = otherUid(cid)
        guard let sk = mySecretKey, let current = lock.withLock({ pubCache[uid] }) else { return decrypt(raw, cid: cid) }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let nonce = Data(base64Encoded: parts[1]), let box = Data(base64Encoded: parts[2]),
              sodium.box.open(authenticatedCipherText: Bytes(box), senderPublicKey: current,
                              recipientSecretKey: sk, nonce: Bytes(nonce)) == nil else { return decrypt(raw, cid: cid) }
        for old in earlierKeys(uid) where old != current {
            if let o = sodium.box.open(authenticatedCipherText: Bytes(box), senderPublicKey: old,
                                       recipientSecretKey: sk, nonce: Bytes(nonce)),
               let text = String(bytes: o, encoding: .utf8) {
                _ = adoptKey(uid, Data(old))
                return text
            }
        }
        return decrypt(raw, cid: cid)
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
        let keys = await preloadKeys(members)   // 2026-09-24 fix-all #118: fetched together, not one by one
        for uid in Set(members) {
            guard let pub = keys[uid] else { continue }   // skip keyless members
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
        // 2026-10-19 groups v2: a file a group stored in the clear (EncMeta.plain) is the file.
        // ⛔ GROUPS ONLY (owner 2026-10-23). A 1:1 file is always sealed; a "plain" meta in a 1:1 is
        // a file nobody sealed, and showing it would pass it off as end-to-end. Refused.
        if meta.isPlain { return Self.isGroupCid(cid) ? cipher : nil }
        // Group media (meta.w present): unwrap MY copy of the file key with the AUTHOR's key.
        if let wraps = meta.w, let author = meta.a {
            // A key released to the group (see "Released group keys") opens it without a wrap of mine.
            func openReleased() -> Data? {
                guard Self.isGroupCid(cid), let key = releasedKey(meta.n),
                      let dataNonce = Data(base64Encoded: meta.n),
                      let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(cipher),
                                                         secretKey: key, nonce: Bytes(dataNonce)) else { return nil }
                return Data(opened)
            }
            do { try await ensureReady(); _ = await preloadKey(author) } catch {}
            guard let sk = mySecretKey, let me = currentUid(),
                  let myWrap = wraps[me],
                  let authorPub = lock.withLock({ pubCache[author] }) else { return openReleased() }
            let wp = myWrap.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard wp.count == 2,
                  let wrappedKey = Data(base64Encoded: wp[0]),
                  let keyNonce = Data(base64Encoded: wp[1]),
                  let dataNonce = Data(base64Encoded: meta.n) else { return openReleased() }
            guard let fileKey = openFrom(author, current: authorPub, box: Bytes(wrappedKey),
                                         nonce: Bytes(keyNonce), sk: sk) else { return openReleased() }
            guard let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(cipher),
                                                     secretKey: fileKey, nonce: Bytes(dataNonce)) else { return openReleased() }
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

        guard let fileKey = openFrom(otherUid(cid), current: otherPub, box: Bytes(wrappedKey),
                                     nonce: Bytes(keyNonce), sk: sk) else {
            // Same key-rotation recovery the text path uses: a wrap that will not open is the
            // signature of a stale peer key, so drop it and refetch for the next attempt.
            // Once per file per session (2026-09-24 fix-all #70), keyed by its wrap nonce.
            refreshKeyAfterFailure(otherUid(cid), item: meta.kn)
            Telemetry.event(.warning, component: "crypto", code: "decrypt_file_failed")   // owner 2026-10-21
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
        let keys = await preloadKeys(members)   // 2026-09-24 fix-all #118: fetched together, not one by one
        for uid in Set(members) {
            // Skip members who haven't published a key yet — they'll see "…" until they do.
            // One keyless member must NOT block the whole group (unlike a 1:1 chat).
            guard let pub = keys[uid] else { continue }
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
    /// A sealed group message (an old end-to-end group, "encg1:") that was never sealed for me: I
    /// was not a member when it was sent, so no key on this phone can ever open it. Only a
    /// readable envelope with no entry for me counts; a damaged one is not this.
    /// A key released to the group (see "Released group keys") counts as mine: such a message is
    /// readable, so it is not "skipped".
    func groupEnvelopeSkipsMe(_ raw: String, cid: String) -> Bool {
        guard raw.hasPrefix("encg1:"), let me = currentUid() else { return false }
        guard let data = Data(base64Encoded: String(raw.dropFirst("encg1:".count))),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wraps = obj["w"] as? [String: String] else { return false }
        if wraps[me] != nil { return false }
        if Self.isGroupCid(cid), let n = obj["n"] as? String, releasedKey(n) != nil { return false }
        return true
    }

    func decryptGroup(_ raw: String, authorId: String, cid: String = "") -> String {
        guard raw.hasPrefix("encg1:") else { return raw }
        warmIfNeeded()
        let b64 = String(raw.dropFirst("encg1:".count))
        guard let jsonData = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let nB64 = obj["n"] as? String, let cB64 = obj["c"] as? String,
              let wraps = obj["w"] as? [String: String],
              let dataNonce = Data(base64Encoded: nB64),
              let ct = Data(base64Encoded: cB64) else { return "🔒" }
        // The released key, when my own wrap is missing or will not open (groups only).
        func openReleased() -> String? {
            guard Self.isGroupCid(cid), let key = releasedKey(nB64),
                  let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(ct),
                                                     secretKey: key, nonce: Bytes(dataNonce)) else { return nil }
            return String(bytes: opened, encoding: .utf8)
        }
        guard let sk = mySecretKey, let me = currentUid() else { return openReleased() ?? "…" }
        guard let authorPub = lock.withLock({ pubCache[authorId] }) else { return openReleased() ?? "…" }
        guard let myWrap = wraps[me] else { return openReleased() ?? "🔒" }
        let wp = myWrap.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard wp.count == 2,
              let wrappedKey = Data(base64Encoded: wp[0]),
              let keyNonce = Data(base64Encoded: wp[1]) else { return openReleased() ?? "🔒" }
        guard let msgKey = openFrom(authorId, current: authorPub, box: Bytes(wrappedKey),
                                    nonce: Bytes(keyNonce), sk: sk) else {
            if let t = openReleased() { return t }
            Telemetry.event(.warning, component: "crypto", code: "decrypt_group_failed"); return "🔒"   // owner 2026-10-21
        }
        guard let opened = sodium.secretBox.open(authenticatedCipherText: Bytes(ct),
                                                 secretKey: msgKey, nonce: Bytes(dataNonce)),
              let text = String(bytes: opened, encoding: .utf8) else { return openReleased() ?? "🔒" }
        return text
    }

    /// Routing decrypt: group envelopes need the author's key; 1:1 uses the cid pair.
    func decrypt(_ raw: String, cid: String, authorId: String) -> String {
        if raw.hasPrefix("encg1:") { return decryptGroup(raw, authorId: authorId, cid: cid) }
        return decrypt(raw, cid: cid)
    }

    // MARK: - Released group keys (owner 2026-10-23: groups are not end-to-end encrypted)
    //
    // Every member of a group reads its whole history, the ones who joined later included, unless
    // the admins hid it. Old group content was sealed ("encg1:", files with `EncMeta.w`) for the
    // members of the day only. A member who holds a wrap sends the per-item key to the server
    // (GroupKeyRelease, callable `releaseGroupKeys`), the server checks it really opens that item,
    // and files it on the message under `rk`, keyed by the item's own data nonce. Here those keys
    // are kept by nonce and tried when my own wrap is missing. GROUP CIDS ONLY: a 1:1 never feeds
    // this store and never reads from it, so nothing here touches 1:1 end-to-end encryption.
    // secretbox.open still authenticates every item, so a wrong key can only fail, never mislead.

    /// A group id. 1:1 ids are "uidA_uidB"; group ids never contain "_".
    static func isGroupCid(_ cid: String) -> Bool { !cid.isEmpty && !cid.contains("_") }

    private var released: [Data: Bytes] = [:]   // data nonce -> 32-byte item key
    private let releasedLock = NSLock()

    /// Standard or URL-safe base64, padded or not.
    static func looseBase64(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Takes a message's (or conversation's) `rk` map. Returns the nonces that were new here, so the
    /// caller can retry media that was marked unreadable. Ignored outside groups.
    @discardableResult
    func noteReleased(cid: String, rk: Any?) -> Set<Data> {
        guard Self.isGroupCid(cid), let map = rk as? [String: Any], !map.isEmpty else { return [] }
        var fresh = Set<Data>()
        releasedLock.withLock {
            for (n, v) in map {
                guard let s = v as? String, let nonce = Self.looseBase64(n), nonce.count == 24,
                      let key = Self.looseBase64(s), key.count == 32, released[nonce] == nil else { continue }
                if released.count > 20_000 { released.removeAll() }   // bounded; parsing refills
                released[nonce] = Bytes(key)
                fresh.insert(nonce)
            }
        }
        return fresh
    }

    /// The released key for the item whose data nonce is `nonceB64`, if any.
    func releasedKey(_ nonceB64: String) -> Bytes? {
        guard let nonce = Self.looseBase64(nonceB64) else { return nil }
        return releasedLock.withLock { released[nonce] }
    }

    /// For GroupKeyRelease: the key of a sealed group text that I can open with my own wrap, checked
    /// against the ciphertext. Returns (data nonce, key) in base64. Never logged.
    func ownGroupTextKey(_ raw: String, authorId: String) -> (n: String, k: String)? {
        guard raw.hasPrefix("encg1:"), let sk = mySecretKey, let me = currentUid(),
              let authorPub = lock.withLock({ pubCache[authorId] }),
              let jsonData = Data(base64Encoded: String(raw.dropFirst("encg1:".count))),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let nB64 = obj["n"] as? String, let cB64 = obj["c"] as? String,
              let wraps = obj["w"] as? [String: String], let myWrap = wraps[me],
              let dataNonce = Data(base64Encoded: nB64), let ct = Data(base64Encoded: cB64) else { return nil }
        let wp = myWrap.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard wp.count == 2, let wrappedKey = Data(base64Encoded: wp[0]), let keyNonce = Data(base64Encoded: wp[1]),
              let key = openFrom(authorId, current: authorPub, box: Bytes(wrappedKey), nonce: Bytes(keyNonce), sk: sk),
              sodium.secretBox.open(authenticatedCipherText: Bytes(ct), secretKey: key, nonce: Bytes(dataNonce)) != nil
        else { return nil }
        return (nB64, Data(key).base64EncodedString())
    }

    /// For GroupKeyRelease: the key of a sealed group FILE that my own wrap opens. Not checked against
    /// the bytes (that needs the download); the server checks it. Never logged.
    func ownGroupFileKey(_ meta: EncMeta) -> (n: String, k: String)? {
        guard !meta.isPlain, let wraps = meta.w, let author = meta.a, !meta.n.isEmpty,
              let sk = mySecretKey, let me = currentUid(), let myWrap = wraps[me],
              let authorPub = lock.withLock({ pubCache[author] }) else { return nil }
        let wp = myWrap.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard wp.count == 2, let wrappedKey = Data(base64Encoded: wp[0]), let keyNonce = Data(base64Encoded: wp[1]),
              let key = openFrom(author, current: authorPub, box: Bytes(wrappedKey), nonce: Bytes(keyNonce), sk: sk),
              key.count == 32 else { return nil }
        return (meta.n, Data(key).base64EncodedString())
    }

    // MARK: - Group seal, with or without end-to-end encryption (owner 2026-10-19)
    //
    // Groups stop end-to-end encryption for new messages. A group that switched (its document says
    // `e2ee == false`, see ChatService.groupIsPlain) carries text and files IN THE CLEAR: protected
    // in transit and by the database and storage rules, not by keys only the members hold. A group
    // that has not switched is sealed exactly as before. Every group send path calls these two; 1:1
    // chats never do. Old "encg1:" messages and sealed files still open through the paths above.

    func sealForGroup(_ text: String, members: [String], cid: String) async throws -> String {
        if await ChatService.groupIsPlain(cid) { return text }
        return try await encryptForGroup(text, members: members)
    }

    func sealBytesForGroup(_ data: Data, members: [String], cid: String) async throws -> (cipher: Data, meta: EncMeta) {
        if await ChatService.groupIsPlain(cid) { return (data, .plain) }
        return try await encryptBytesForGroup(data, members: members)
    }
}

extension Notification.Name {
    /// This account's keypair is loaded (posted on main). Views holding "…" previews redraw.
    static let cryptoIdentityReady = Notification.Name("kulan.cryptoIdentityReady")
    /// A group file's released key arrived (MediaDownloads.clearUnreadable); userInfo "url". Posted
    /// on main. A view that drew it as unreadable tries again.
    static let groupKeyReleased = Notification.Name("kulan.groupKeyReleased")
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

    /// Like `get`, but tells "not there" (`notFound`) apart from "could not be read right now" (the
    /// phone has not been unlocked since it started), which `get` reports the same way.
    static func lookup(_ key: String) -> (value: String?, notFound: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return (nil, status == errSecItemNotFound)
        }
        return (String(data: data, encoding: .utf8), false)
    }

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
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
        // ⛔ THE RESULT IS THE POINT. This was discarded, and `initKeys` then published the public
        // half unconditionally — so a keychain that refused the write left the account ADVERTISING a
        // key whose private half existed only in memory. That session worked. The next launch found
        // nothing, generated a second keypair, republished, and everything anyone had sealed to the
        // first key became permanently unreadable, surfacing as a lock glyph with no explanation
        // anywhere.
        //
        // Reported rather than thrown: the caller decides what a storage failure means, and for the
        // identity key it must mean "do not publish".
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
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
