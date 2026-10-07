import Foundation
import Observation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// CALL LINKS, the reference app's model. A link is a 16-byte root key that only ever lives in the
// link itself and in the creator's own saved list. Everything the server sees is derived from it
// one way:
//   · roomId   = hex(HKDF-SHA256(rootKey, info "kulan-calllink-roomid-v1"))  → callLinks/{roomId}
//   · name key = HKDF-SHA256(rootKey, info "kulan-calllink-name-v1")         → encName (AES.GCM)
// So the server can tell a link exists and who made it, but cannot read its name or rebuild the
// link from what it stores.
//
// TWO SPELLINGS OF THE SAME KEY (owner, 2026-10-07):
//   · https://call.fariin.com/video/<id>  and  /voice/<id>  : what the app hands out now. <id> is
//     the key as 22 base62 characters (`compact`). The path names the call type, so a shared link
//     says what it is before anyone opens it. This form DOES reach the web server when somebody
//     without the app opens it: that is the owner's trade, a readable short link over a key that
//     never left the phone. Nothing about the server contract changes with it.
//   · https://fariin.com/call/#key=bcdf-ghkm-…  : the old form, 32 consonants in 8 groups
//     (`text`). Read for ever: it sits in old chats. Never produced any more.

/// The root key of one call link, and everything derived from it.
struct CallLinkKey: Hashable {
    let bytes: Data

    /// 16 letters, no vowels and no look-alikes, so a key read aloud or typed by hand survives.
    /// One letter per nibble, high nibble first.
    private static let alphabet = Array("bcdfghkmnpqrstxz")

    static func generate() -> CallLinkKey {
        while true {
            // `UInt8.random` draws from SystemRandomNumberGenerator, which is the system CSPRNG.
            let raw = (0..<16).map { _ in UInt8.random(in: 0...255) }
            if let key = CallLinkKey(raw: Data(raw)) { return key }
        }
    }

    /// nil when any 2-byte chunk is one nibble repeated four times ("bbbb", "zzzz"): such a group
    /// looks like filler, and refusing it on both sides keeps every valid key looking random.
    private init?(raw: Data) {
        guard raw.count == 16 else { return nil }
        let b = [UInt8](raw)
        for i in stride(from: 0, to: 16, by: 2) {
            let n = [b[i] >> 4, b[i] & 0x0f, b[i + 1] >> 4, b[i + 1] & 0x0f]
            if n.allSatisfy({ $0 == n[0] }) { return nil }
        }
        bytes = raw
    }

    /// Reads the text form back. Dashes and case are forgiven; anything else is refused.
    init?(text: String) {
        let clean = text.lowercased().filter { $0 != "-" && !$0.isWhitespace }
        guard clean.count == 32 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        var high: UInt8?
        for ch in clean {
            guard let idx = Self.alphabet.firstIndex(of: ch) else { return nil }
            let nib = UInt8(idx)
            if let h = high { out.append(h << 4 | nib); high = nil } else { high = nib }
        }
        self.init(raw: Data(out))
    }

    /// "bcdf-ghkm-…": 8 groups of 4 letters.
    var text: String {
        var letters: [Character] = []
        for byte in bytes {
            letters.append(Self.alphabet[Int(byte >> 4)])
            letters.append(Self.alphabet[Int(byte & 0x0f)])
        }
        return stride(from: 0, to: letters.count, by: 4)
            .map { String(letters[$0..<min($0 + 4, letters.count)]) }
            .joined(separator: "-")
    }

    private func derive(_ info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes),
                               salt: Data(),
                               info: Data(info.utf8),
                               outputByteCount: 32)
    }

    /// The Firestore id of this link: lowercase hex of the derived 32 bytes.
    var roomId: String {
        derive("kulan-calllink-roomid-v1").withUnsafeBytes { raw in
            raw.map { String(format: "%02x", $0) }.joined()
        }
    }

    // THE PATH FORM. The 16 bytes read as one unsigned 128-bit number, most significant byte
    // first, written in base 62 with this alphabet (ASCII order: digits, then A-Z, then a-z), ALWAYS
    // 22 digits, "0"-padded on the left. 62^21 < 2^128 < 62^22, so 22 is the fixed width and a
    // value of 2^128 or more is not a key. Case matters. A web page or a server decodes it the
    // same way: value = value * 62 + digit, left to right, then the 16 big-endian bytes.
    private static let base62 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static let compactLength = 22

    /// The 22-character path id of this key.
    var compact: String {
        // Long division of the big-endian bytes by 62, lowest digit first. Each pass leaves the
        // quotient in `num`; after 22 passes it is zero, which is what fixes the width.
        var num = [UInt8](bytes)
        var digits = [Character](repeating: "0", count: Self.compactLength)
        for pos in stride(from: Self.compactLength - 1, through: 0, by: -1) {
            var rem = 0
            for i in num.indices {
                let cur = rem << 8 | Int(num[i])      // < 62 * 256, so the quotient fits a byte
                num[i] = UInt8(cur / 62)
                rem = cur % 62
            }
            digits[pos] = Self.base62[rem]
        }
        return String(digits)
    }

    /// Reads the path id back. Exactly 22 characters of the alphabet, nothing forgiven: this is
    /// what arrives from a tapped link, and a near-miss is not a key.
    init?(compact: String) {
        guard compact.count == Self.compactLength else { return nil }
        var num = [UInt8](repeating: 0, count: 16)
        for ch in compact {
            guard let d = Self.base62.firstIndex(of: ch) else { return nil }
            var carry = d
            for i in stride(from: 15, through: 0, by: -1) {
                let cur = Int(num[i]) * 62 + carry
                num[i] = UInt8(cur & 0xff)
                carry = cur >> 8
            }
            guard carry == 0 else { return nil }       // 2^128 or more: not a key
        }
        self.init(raw: Data(num))
    }

    /// The host of a shared link. `KulanApp.linkHost` is the main site; call links have their own
    /// host so the address reads as what it is, and so iOS can be told about it separately.
    static let linkHost = "call.fariin.com"

    /// The link people are sent: https://call.fariin.com/video/<id>, or /voice/<id> for a voice
    /// link. Every place that hands a link out knows which it is (the draft's Call Type, the saved
    /// link's doc, the running call's answer from the server), so the type is not defaulted here.
    func url(video: Bool) -> URL {
        URL(string: "https://\(Self.linkHost)/\(video ? "video" : "voice")/\(compact)")!
    }

    /// Base64 of AES.GCM's combined box (nonce + ciphertext + tag). "" for an empty name, which is
    /// what the server stores for an unnamed link.
    func encryptName(_ name: String) -> String {
        guard !name.isEmpty,
              let box = try? AES.GCM.seal(Data(name.utf8), using: derive("kulan-calllink-name-v1")),
              let combined = box.combined else { return "" }
        return combined.base64EncodedString()
    }

    func decryptName(_ enc: String) -> String? {
        guard !enc.isEmpty else { return "" }
        guard let data = Data(base64Encoded: enc),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: derive("kulan-calllink-name-v1")) else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}

/// Outside the service on purpose: the service is main-actor, and the row models read these.
enum CallLinkDefaults {
    static let name = "Kulan Call"
    static let maxNameLength = 32
    /// The server rules cap a stored name at 64 code points (`name.size() <= 64`), which counts
    /// unicode scalars, not the grapheme clusters `String.count` and `prefix` use.
    static let maxNameScalars = 64

    /// Cuts a name to the visible cap AND the rules' scalar cap, whole characters only.
    /// owner audit 2026-10-06 #44: 32 long emoji sequences passed the old Character cap, the
    /// rules denied the list write, and the name was lost on reload.
    static func clamp(_ name: String) -> String {
        var out = String(name.prefix(maxNameLength))
        while out.unicodeScalars.count > maxNameScalars { out.removeLast() }
        return out
    }
}

/// Anything that names one call link: a fresh draft or a saved row.
protocol CallLinkRef {
    var roomId: String { get }
    var key: String { get }        // the formatted root key (`CallLinkKey.text`)
}

extension CallLinkRef {
    var linkKey: CallLinkKey? { CallLinkKey(text: key) }
    /// The link to hand out; nil only for a key that does not parse. The caller says which call
    /// type the link is, see `CallLinkKey.url(video:)`.
    func url(video: Bool) -> URL? { linkKey?.url(video: video) }
}

/// One link in my Calls list (users/{me}/callLinks/{roomId}).
struct SavedCallLink: Identifiable, Hashable, CallLinkRef {
    let roomId: String
    let key: String
    var name: String               // "" = unnamed
    let createdAt: Date
    let admin: Bool
    var id: String { roomId }

    /// What the row and the card show.
    var title: String { name.isEmpty ? CallLinkDefaults.name : name }
}

/// A link that exists on the server but is not in my list yet. It goes into the list on Done,
/// Join, Copy or Share (`CallLinkService.persist`), the way the reference app keeps a link you
/// created and then threw away out of your history.
struct CallLinkDraft: Identifiable, Hashable, CallLinkRef {
    let roomId: String
    let key: String
    var name: String               // "" = unnamed
    var approval: Bool             // "Require Admin Approval"
    var video: Bool = true         // Call Type: Video, or Voice (owner, 2026-10-06)
    var id: String { roomId }

    var title: String { name.isEmpty ? CallLinkDefaults.name : name }
}

@MainActor
@Observable
final class CallLinkService {
    static let shared = CallLinkService()
    private init() {}

    var links: [SavedCallLink] = []
    var hasLoaded = false

    /// Bumped by reset(), so a load still in flight when the account changes cannot publish the
    /// previous account's links afterwards (the same guard CallsRepository keeps).
    private var generation = 0

    /// Local changes (a persist, rename or delete) with a running stamp; nil link = deleted here.
    /// owner audit 2026-10-06 #23: a load() that started before a local change was acknowledged
    /// returned the old doc and overwrote the fresh name with "" (row showed "Kulan Call").
    /// load() re-applies every change stamped after it began instead of replacing blindly.
    private var editStamp = 0
    private var edits: [String: (stamp: Int, link: SavedCallLink?)] = [:]

    private func noteEdit(_ roomId: String, _ link: SavedCallLink?) {
        editStamp += 1
        edits[roomId] = (editStamp, link)
    }

    private var functions: Functions { Functions.functions(region: "me-central1") }
    private var me: String? { Auth.auth().currentUser?.uid }

    private func listRef(_ uid: String) -> CollectionReference {
        Firestore.firestore().collection("users").document(uid).collection("callLinks")
    }

    /// Sign-out/delete: drop the previous account's links.
    func reset() {
        generation &+= 1
        prepared = nil; preparing?.cancel(); preparing = nil   // a link made for the previous account
        edits = [:]
        links = []
        hasLoaded = false
    }

    func load() async {
        guard let me else { hasLoaded = true; return }
        let gen = generation
        let startStamp = editStamp
        guard let snap = try? await listRef(me).getDocuments() else {
            if gen == generation { hasLoaded = true }
            return
        }
        guard gen == generation else { return }
        // Sorted here rather than by the query: an orderBy on a subcollection this small is not
        // worth an index, and a doc whose server timestamp is still pending would drop out of it.
        var loaded = snap.documents.compactMap { d -> SavedCallLink? in
            let data = d.data(with: .estimate)
            guard let key = data["key"] as? String, CallLinkKey(text: key) != nil else { return nil }
            return SavedCallLink(roomId: d.documentID, key: key,
                                 name: data["name"] as? String ?? "",
                                 createdAt: (data["createdAt"] as? Timestamp)?.dateValue() ?? Date(),
                                 admin: data["admin"] as? Bool ?? false)
        }
        // Local changes made while the read was in flight win over what it returned (#23).
        for (id, e) in edits where e.stamp > startStamp {
            loaded.removeAll { $0.roomId == id }
            if let l = e.link { loaded.append(l) }
        }
        links = loaded.sorted { $0.createdAt > $1.createdAt }
        hasLoaded = true
    }

    /// ⛔ ONE LINK MADE AHEAD — owner, 2026-10-06: "Create a Call Link" sat on a spinner. Each tap
    /// waited for a server round trip, and a cold function start on top of it. The Calls tab now asks
    /// for one link in the background (`prepare`) and the tap takes it at once; the next one is made
    /// behind it. An unused one is just an unsaved link (nothing is in anybody's list until Done,
    /// Join, Copy or Share), it expires on its own, and at most one exists per session.
    private var prepared: CallLinkDraft?
    private var preparing: Task<CallLinkDraft?, Never>?

    func prepare() {
        guard prepared == nil, preparing == nil, me != nil else { return }
        preparing = Task { @MainActor [weak self] in
            let d = try? await self?.makeOnServer()
            self?.preparing = nil
            if self?.prepared == nil { self?.prepared = d }
            return d
        }
    }

    /// Hands back a ready link: the one made ahead if there is one (or is about to be), else a new one.
    func create() async throws -> CallLinkDraft {
        if let d = prepared { prepared = nil; prepare(); return d }
        if let t = preparing, let d = await t.value {
            if prepared?.roomId == d.roomId { prepared = nil }
            prepare()
            return d
        }
        let d = try await makeOnServer()
        prepare()
        return d
    }

    /// Makes a new link on the server (me as its admin, approval ON) and hands back the draft.
    /// Nothing is saved to my list yet.
    private func makeOnServer() async throws -> CallLinkDraft {
        // A collision on a fresh 128-bit key is not going to happen; the retry is there so an
        // 'already-exists' from the server can never surface as a failed create.
        var lastError: Error?
        for _ in 0..<3 {
            let key = CallLinkKey.generate()
            do {
                _ = try await functions.httpsCallable("createCallLink").call([
                    "roomId": key.roomId,
                    "encName": "",
                    "restrictions": "adminApproval",
                    "video": true,
                ])
                return CallLinkDraft(roomId: key.roomId, key: key.text, name: "", approval: true)
            } catch {
                lastError = error
                let ns = error as NSError
                guard ns.domain == FunctionsErrorDomain,
                      FunctionsErrorCode(rawValue: ns.code) == .alreadyExists else { throw error }
            }
        }
        throw lastError ?? NSError(domain: "CallLink", code: 1)
    }

    /// Puts a link into my Calls list. Safe to call more than once (Done after Copy, and so on).
    func persist(_ draft: CallLinkDraft) async {
        guard let me else { return }
        let saved = SavedCallLink(roomId: draft.roomId, key: draft.key, name: draft.name,
                                  createdAt: Date(), admin: true)
        var fields: [String: Any] = [
            "key": draft.key,
            "name": draft.name,
            "admin": true,
        ]
        if let i = links.firstIndex(where: { $0.roomId == draft.roomId }) {
            links[i].name = draft.name
            noteEdit(draft.roomId, links[i])
        } else {
            links.insert(saved, at: 0)
            noteEdit(draft.roomId, saved)
            // owner audit 2026-10-06 #44: the order time is written on the first save only; every
            // later Copy/Share/Done used to move it to the last tap.
            fields["createdAt"] = FieldValue.serverTimestamp()
        }
        try? await listRef(me).document(draft.roomId).setData(fields, merge: true)
    }

    /// Renames on the server (encrypted) and, if the link is in my list, there too.
    func rename(_ link: some CallLinkRef, to name: String) async throws {
        guard let key = link.linkKey else { throw NSError(domain: "CallLink", code: 2) }
        let clean = CallLinkDefaults.clamp(name.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try await functions.httpsCallable("updateCallLink").call([
            "roomId": link.roomId,
            "encName": key.encryptName(clean),
        ])
        if let i = links.firstIndex(where: { $0.roomId == link.roomId }) {
            links[i].name = clean
            noteEdit(link.roomId, links[i])
            if let me {
                // owner audit 2026-10-06 #44: not awaited. The server name is already changed, and
                // waiting for the write's server ack hung the Save spinner when the network dropped
                // here. Firestore applies it locally at once and syncs it when it can.
                listRef(me).document(link.roomId).setData(["name": clean], merge: true, completion: nil)
            }
        }
    }

    func setApproval(_ link: some CallLinkRef, on: Bool) async throws {
        _ = try await functions.httpsCallable("updateCallLink").call([
            "roomId": link.roomId,
            "restrictions": on ? "adminApproval" : "none",
        ])
    }

    /// Call Type (owner, 2026-10-06): Video, or Voice. A Voice link lets nobody turn a camera on; the
    /// server mints its join tokens microphone-only. A Video link joins with the camera on and each
    /// person can still turn their own camera off.
    func setVideo(_ link: some CallLinkRef, on: Bool) async throws {
        _ = try await functions.httpsCallable("updateCallLink").call([
            "roomId": link.roomId,
            "video": on,
        ])
    }

    /// Owner (group call permissions, 2026-10-06): no one new can join with this link. A call already
    /// running on it goes on, and its owner can still get back in while anyone is there.
    func revoke(_ link: some CallLinkRef) async throws {
        _ = try await functions.httpsCallable("updateCallLink").call([
            "roomId": link.roomId,
            "revoked": true,
        ])
    }

    /// Whether the link was revoked, from its own doc. nil when it cannot be read.
    func isRevoked(_ link: some CallLinkRef) async -> Bool? {
        guard let snap = try? await Firestore.firestore().collection("callLinks")
            .document(link.roomId).getDocument(), let d = snap.data() else { return nil }
        return d["revoked"] as? Bool ?? false
    }

    /// Owner: a new link in place of `old`. The server revokes the old one and copies its approval
    /// and call type to the new one; the name is sealed with a key derived from the link's own root
    /// key, so it is opened here with the old key and sealed again for the new one. The new link
    /// takes the old one's place in my Calls list.
    func regenerate(_ old: some CallLinkRef) async throws -> ActiveCallLink {
        guard let oldKey = old.linkKey else { throw NSError(domain: "CallLink", code: 2) }
        var name = links.first(where: { $0.roomId == old.roomId })?.name
        if name == nil,
           let enc = try? await Firestore.firestore().collection("callLinks").document(old.roomId)
               .getDocument().data()?["encName"] as? String {
            name = oldKey.decryptName(enc)
        }
        // Unreadable name: sent empty rather than the old sealed one, which the new key cannot open.
        let clean = CallLinkDefaults.clamp(name ?? "")
        var lastError: Error?
        for _ in 0..<3 {
            let key = CallLinkKey.generate()
            do {
                _ = try await functions.httpsCallable("regenerateCallLink").call([
                    "roomId": old.roomId,
                    "newRoomId": key.roomId,
                    "encName": key.encryptName(clean),
                ])
                await replaceSaved(old.roomId, with: key, name: clean)
                return ActiveCallLink(roomId: key.roomId, key: key.text)
            } catch {
                // Same rule as makeOnServer: only a roomId collision is worth another key.
                lastError = error
                let ns = error as NSError
                guard ns.domain == FunctionsErrorDomain,
                      FunctionsErrorCode(rawValue: ns.code) == .alreadyExists else { throw error }
            }
        }
        throw lastError ?? NSError(domain: "CallLink", code: 1)
    }

    /// The old link's row leaves my list and the new one goes in at the top, same name, admin.
    private func replaceSaved(_ oldId: String, with key: CallLinkKey, name: String) async {
        guard let me else { return }
        let fresh = SavedCallLink(roomId: key.roomId, key: key.text, name: name, createdAt: Date(), admin: true)
        links.removeAll { $0.roomId == oldId || $0.roomId == fresh.roomId }
        noteEdit(oldId, nil)
        links.insert(fresh, at: 0)
        noteEdit(fresh.roomId, fresh)
        try? await listRef(me).document(fresh.roomId).setData([
            "key": fresh.key,
            "name": name,
            "admin": true,
            "createdAt": FieldValue.serverTimestamp(),
        ], merge: true)
        try? await listRef(me).document(oldId).delete()
    }

    /// The link's call type from its own doc: true = Video (every link made before the setting).
    func isVideo(_ link: some CallLinkRef) async -> Bool? {
        guard let snap = try? await Firestore.firestore().collection("callLinks")
            .document(link.roomId).getDocument(), let d = snap.data() else { return nil }
        return (d["video"] as? Bool) ?? true
    }

    /// The current approval setting, read from the link's own doc. nil when it cannot be read.
    func approval(for link: some CallLinkRef) async -> Bool? {
        guard let snap = try? await Firestore.firestore().collection("callLinks")
            .document(link.roomId).getDocument(),
              let r = snap.data()?["restrictions"] as? String else { return nil }
        return r == "adminApproval"
    }

    /// The creator deletes the link for everyone; anyone else only drops it from their own list.
    func delete(_ link: SavedCallLink) async throws {
        if link.admin {
            do {
                _ = try await functions.httpsCallable("deleteCallLink").call(["roomId": link.roomId])
            } catch {
                // owner audit 2026-10-06 #22: not-found means the link is already gone on the
                // server (deleted on another device); drop the row instead of failing forever.
                let ns = error as NSError
                guard ns.domain == FunctionsErrorDomain,
                      FunctionsErrorCode(rawValue: ns.code) == .notFound else { throw error }
            }
        }
        links.removeAll { $0.roomId == link.roomId }
        noteEdit(link.roomId, nil)
        if let me {
            try? await listRef(me).document(link.roomId).delete()
        }
    }
}
