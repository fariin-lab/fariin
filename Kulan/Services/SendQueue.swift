import Foundation
import FirebaseFirestore

// Durable outgoing-TEXT queue (a durable job queue, minimal form). A text send is
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
        /// ⛔ VOICE NOTES RIDE THIS QUEUE TOO NOW. It was text only, on the reasoning that "media
        /// payloads are large and already have retry affordances" — but the affordance was a red
        /// bubble you had to notice and tap, while a text message that failed on the same weak
        /// signal quietly resent itself. The one that took effort to record was the one that did not.
        ///
        /// The AUDIO ITSELF IS NOT STORED HERE. UserDefaults is no place for megabytes, and it
        /// already lives in a file — `AudioRecorder.parkInFlight` writes it and keys it by clientId,
        /// so this only has to remember that the file is waiting and what to send it as.
        var audioDuration: Double? = nil
        var audioWaveform: [Int]? = nil
        /// 2026-09-24 decision D-composer-2: the server refused this send (a rule said no), so no
        /// automatic path sends it again. The entry is kept only so the chat can still draw it as a
        /// failed bubble with Resend / Delete; a Resend re-adds it without this flag.
        var refused: Bool? = nil
    }

    /// 2026-09-24 decision D-composer-2: a refusal that waiting cannot fix, told apart from
    /// "offline". Same wire numbers `StoriesService.isPermanentPostFailure` uses (3 invalidArgument ·
    /// 7 permissionDenied · 9 failedPrecondition · 16 unauthenticated).
    static func isPermanentRefusal(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == FirestoreErrorDomain && [3, 7, 9, 16].contains(ns.code)
    }

    static func isRefused(clientId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return load()[clientId]?.refused == true
    }

    /// Keeps the entry but takes it out of every automatic retry (see `Entry.refused`).
    static func markRefused(clientId: String) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        guard map[clientId] != nil else { return }
        map[clientId]?.refused = true
        save(map)
    }

    private static let key = "sendQueue.v1"
    private static let lock = NSLock()

    /// ⛔ ONE SEND PER clientId AT A TIME, in this process (2026-09-24 audit). An offline send does
    /// not fail, it SUSPENDS: the Firestore await returns only when the server answers. Meanwhile the
    /// stuck-send sweep marks the bubble failed after 5s, and a Retry tap, a reopen of the chat
    /// (a new view, a new drain) or the launch drain each started a SECOND send of the same entry.
    /// `alreadySent` cannot see a message that is not even written yet, so on reconnect both went
    /// out and the other person got the text twice. Every sender claims the id first.
    private static var inFlight = Set<String>()

    /// False when this clientId is already being sent; the caller must not send it again.
    static func beginSending(_ clientId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(clientId).inserted
    }

    static func endSending(_ clientId: String) {
        lock.lock(); defer { lock.unlock() }
        inFlight.remove(clientId)
    }

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

    /// Queues a voice note whose send failed. The bytes are already parked on disk by the recorder;
    /// this is the note that they are owed a retry.
    static func addAudio(clientId: String, cid: String, duration: Double, waveform: [Int],
                         reply: ReplyRef?, ts: Double) {
        lock.lock(); defer { lock.unlock() }
        var map = load()
        map[clientId] = Entry(clientId: clientId, cid: cid, text: "", mentions: [],
                              replyId: reply?.id, replyAuthor: reply?.authorId, replyText: reply?.text,
                              createdAt: ts, audioDuration: duration, audioWaveform: waveform)
        save(map)
    }

    /// Sign-out/delete: unsent plaintext from the old account must not be re-driven
    /// (or readable) under the next account.
    static func removeAll() {
        lock.lock(); defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
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

    /// Re-drive EVERY queued send, whatever chat it belongs to. The header above promises a message
    /// survives an app kill and goes out "on the next launch", but the only drain was per-chat, on
    /// chat open — so a message actually sat unsent until the user happened to reopen that exact
    /// conversation, with no visual trace (the optimistic bubble is memory-only), meaning they had
    /// no reason to (audit). Called once at launch, after sign-in.
    ///
    /// Skips the chat currently on screen: ThreadView drains that one itself, with its optimistic
    /// bubble. `alreadySent` still guards against re-sending anything that landed before the kill.
    @MainActor
    static func drainAll() async {
        let open = AppRouter.shared.activeChatId
        // 2026-09-24 decision D-composer-2: a refused send is never re-driven automatically.
        let entries = allPending().filter { $0.cid != open && $0.refused != true }
        for e in entries {
            // The chat may have been opened since this loop started; its own drain then owns it.
            guard beginSending(e.clientId) else { continue }
            defer { endSending(e.clientId) }
            if await alreadySent(cid: e.cid, clientId: e.clientId) { remove(clientId: e.clientId); continue }
            let reply: ReplyRef? = e.replyId.map {
                ReplyRef(id: $0, authorId: e.replyAuthor ?? "", text: e.replyText ?? "")
            }
            do {
                if let dur = e.audioDuration {
                    // The bytes are in the file the recorder parked. If that file is gone there is
                    // nothing left to send, so the entry is dropped rather than retried forever
                    // against a payload that no longer exists.
                    guard let data = AudioRecorder.inFlightData(clientId: e.clientId) else {
                        remove(clientId: e.clientId); continue
                    }
                    try await ChatService.sendAudio(cid: e.cid, data: data, duration: dur,
                                                    waveform: e.audioWaveform ?? [], replyTo: reply,
                                                    clientId: e.clientId, group: nil)
                    AudioRecorder.dropInFlight(clientId: e.clientId)
                } else {
                    // group: nil → sendText resolves members from the conversation doc itself.
                    try await ChatService.sendText(cid: e.cid, text: e.text, replyTo: reply,
                                                   clientId: e.clientId, group: nil, mentions: e.mentions)
                }
                remove(clientId: e.clientId)
            } catch {
                // Still offline: leave it queued for the next launch. 2026-09-24 decision
                // D-composer-2: a rule refusal is flagged instead, so it stops being retried for ever
                // and the chat shows it as failed.
                if isPermanentRefusal(error) { markRefused(clientId: e.clientId) }
            }
        }
    }

    private static func allPending() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load().values.sorted { $0.createdAt < $1.createdAt }
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
