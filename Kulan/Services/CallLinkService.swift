import Foundation
import Observation
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// CALL LINKS, the reference app's model. A link is a 16-byte root key that only ever lives in the
// link itself (after the `#`, so it never reaches a web server) and in the creator's own saved
// list. Everything the server sees is derived from it one way:
//   · roomId   = hex(HKDF-SHA256(rootKey, info "kulan-calllink-roomid-v1"))  → callLinks/{roomId}
//   · name key = HKDF-SHA256(rootKey, info "kulan-calllink-name-v1")         → encName (AES.GCM)
// So the server can tell a link exists and who made it, but cannot read its name or rebuild the
// link from what it stores.

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

    /// The fragment never leaves the phone that opens it, which is the point. Same host as
    /// `KulanApp.linkHost`, spelled out because that constant is main-actor and this is not.
    var url: URL {
        URL(string: "https://fariin.com/call/#key=\(text)")!
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
    var url: URL? { linkKey?.url }
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

    /// Makes a new link on the server (me as its admin, approval ON) and hands back the draft.
    /// Nothing is saved to my list yet.
    func create() async throws -> CallLinkDraft {
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
