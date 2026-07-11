import Foundation
import FirebaseFirestore

// Durable outgoing-TEXT queue (Signal's MessageSenderJobQueue, minimal form). A text send is
// persisted to disk BEFORE the network call and removed only once it succeeds — so a message you
// composed then killed/backgrounded the app on still gets sent on the next launch, instead of
// silently vanishing with the in-memory optimistic bubble.
//
// Scope: TEXT only (the common case; media payloads are large and already have retry affordances).
// Duplicate-safe: re-driving on launch first checks Firestore for a doc with the same clientId and
// skips it if the original actually landed before the app died.
enum SendQueue {
    struct Entry: Codable {
        let clientId: String
        let cid: String
        let text: String
        let mentions: [String]
        let replyId: String?
        let replyAuthor: String?
        let replyText: String?
        let createdAt: Double
    }

    private static let key = "sendQueue.v1"
    private static let lock = NSLock()

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }
    private static func save(_ map: [String: Entry]) {
        if let data = try? JSONEncoder().encode(map) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func add(clientId: String, cid: String, text: String, mentions: [String], reply: ReplyRef?, ts: Double) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        map[clientId] = Entry(clientId: clientId, cid: cid, text: text, mentions: mentions,
                              replyId: reply?.id, replyAuthor: reply?.authorId, replyText: reply?.text,
                              createdAt: ts)
        save(map)
    }

    static func remove(clientId: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        guard map[clientId] != nil else { return }
        map.removeValue(forKey: clientId)
        save(map)
    }

    static func pending(for cid: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load().values.filter { $0.cid == cid }.sorted { $0.createdAt < $1.createdAt }
    }

    /// True if a message with this clientId already exists on the server (the send DID land before the
    /// app died) — so we must NOT re-send it.
    static func alreadySent(cid: String, clientId: String) async -> Bool {
        let db = Firestore.firestore()
        let snap = try? await db.collection("conversations").document(cid).collection("messages")
            .whereField("clientId", isEqualTo: clientId).limit(to: 1).getDocuments()
        return (snap?.documents.isEmpty == false)
    }
}
