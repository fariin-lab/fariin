import Foundation
import FirebaseFunctions
import FirebaseAuth

/// What a quoted channel post's card shows (owner 2026-11-06). Everything here comes from the
/// server's `getQuotes`, which decides per reader, every time, whether the source channel may be
/// seen: `.ok` is the post as it was when quoted, `.deleted` keeps the channel's face and says Post
/// deleted, `.hidden` shows nothing of the post (the channel is private to this reader, or closed).
struct QuoteCard: Equatable, Codable {
    enum State: String, Equatable, Codable { case ok, deleted, hidden, gone }
    var state: State
    var cid = ""
    var mid = ""
    var title = ""
    var photoUrl = ""
    var username = ""
    var text = ""
    /// "text", "photo", "video" or "album".
    var kind = "text"
    var image = ""

    init(state: State) { self.state = state }

    init?(_ d: [String: Any]) {
        switch d["state"] as? String {
        case "ok": state = .ok
        case "deleted": state = .deleted
        case "private": state = .hidden
        case "gone": state = .gone
        default: return nil
        }
        cid = d["cid"] as? String ?? ""
        mid = d["mid"] as? String ?? ""
        title = d["title"] as? String ?? ""
        photoUrl = d["photoUrl"] as? String ?? ""
        username = d["username"] as? String ?? ""
        text = d["text"] as? String ?? ""
        kind = d["kind"] as? String ?? "text"
        image = d["image"] as? String ?? ""
    }

    /// The card's lines, as the bubble draws them.
    var heading: String {
        switch state {
        case .ok, .deleted: return title.isEmpty ? "Channel" : title
        case .hidden, .gone: return "Channel post"
        }
    }

    var body: String {
        switch state {
        case .ok:
            if !text.isEmpty { return text }
            switch kind {
            case "photo": return "Photo"
            case "video": return "Video"
            case "album": return "Album"
            default: return "Post"
            }
        case .deleted: return "Post deleted"
        case .hidden: return "This channel is private"
        case .gone: return "Content unavailable"
        }
    }
}

/// ⛔ THE QUOTE CARDS, ASKED FROM THE SERVER (owner 2026-11-06). Rows ask `card(_:)` as they are
/// drawn; misses and answers older than `fresh` are fetched together (up to 50 ids a call). A
/// changed answer bumps the open chat's rows (`LiveGroupCard.noteChanged`), so a channel that
/// becomes visible again shows its quote without anyone reopening the chat.
@MainActor final class QuoteStore {
    static let shared = QuoteStore()

    nonisolated static func isQid(_ s: String) -> Bool {
        s.count == 16 && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    private var cards: [String: QuoteCard] = [:]
    /// When each card was last drawn: the oldest go first past `keep` (2026-11-06 audit: the old
    /// trim kept an arbitrary 500, so random cards read "Loading…" again after a relaunch).
    private var lastUsed: [String: Date] = [:]
    private let keep = 800
    private var fetchedAt: [String: Date] = [:]
    private var queued = Set<String>()
    private var inFlight = Set<String>()
    private var flushScheduled = false
    /// How long an answer is trusted before the server is asked again (access can change).
    private let fresh: TimeInterval = 120

    /// ⛔ THE CARDS ARE KEPT ON DISK (owner 2026-11-06: after a restart every quote in a channel read
    /// "Loading…" until the server answered). The last answers draw on the first frame; each is still
    /// asked again at once (no `fetchedAt` is restored), so access lost since then hides it within a
    /// moment. One file per account, up to 500 cards.
    private static func fileURL() -> URL? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("quoteCards.\(uid).v1.json")
    }
    private var saveScheduled = false

    private init() {
        if let url = Self.fileURL(), let d = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: QuoteCard].self, from: d) {
            cards = saved
        }
    }

    private func scheduleSave() {
        guard !saveScheduled, let url = Self.fileURL() else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            saveScheduled = false
            let newest = cards.keys.sorted { (lastUsed[$0] ?? .distantPast) > (lastUsed[$1] ?? .distantPast) }.prefix(500)
            let snap = Dictionary(uniqueKeysWithValues: newest.compactMap { k in cards[k].map { (k, $0) } })
            Task.detached(priority: .utility) {
                if let d = try? JSONEncoder().encode(snap) { try? d.write(to: url, options: .atomic) }
            }
        }
    }

    /// The card for `qid`, or nil while the first answer is on its way. Asking also schedules a
    /// refresh when the answer is old.
    func card(_ qid: String) -> QuoteCard? {
        let stale = fetchedAt[qid].map { Date().timeIntervalSince($0) > fresh } ?? true
        if stale { request(qid) }
        if cards[qid] != nil { lastUsed[qid] = Date() }
        return cards[qid]
    }

    /// Past `keep` cards in memory, the least recently drawn go.
    private func trim() {
        guard cards.count > keep else { return }
        let old = cards.keys.sorted { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }.prefix(cards.count - keep)
        for k in old { cards[k] = nil; lastUsed[k] = nil; fetchedAt[k] = nil }
    }

    /// Sign-out (SessionWipe): nothing of this account's cards outlives it, in memory or on disk.
    func reset() {
        // Every account's card file (2026-11-06 audit: sign-out runs after Auth.signOut, so there is no
        // uid left to name this account's file by).
        if let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names where n.hasPrefix("quoteCards.") { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
        }
        for t in pending.values { t.cancel() }
        cards.removeAll(); lastUsed.removeAll(); fetchedAt.removeAll(); queued.removeAll()
        inFlight.removeAll()   // a call from the old account must not block the new one's cards
        pending.removeAll(); done.removeAll()
    }

    /// What the row signature carries for this quote.
    func token(_ qid: String) -> String {
        guard let c = cards[qid] else { return "?" }
        return "\(c.state)\(c.title.hashValue):\(c.text.hashValue):\(c.image.hashValue):\(c.photoUrl.hashValue)"
    }

    /// The answer `createQuote` gave the quoting phone: shown at once, no second request.
    func seed(_ qid: String, _ card: QuoteCard) {
        cards[qid] = card
        fetchedAt[qid] = Date()
        scheduleSave()
    }

    private func request(_ qid: String) {
        guard Self.isQid(qid), !inFlight.contains(qid) else { return }
        queued.insert(qid)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)   // gather a screenful of rows into one call
            flushScheduled = false
            await flush()
        }
    }

    private func flush() async {
        let batch = Array(queued.prefix(50))
        guard !batch.isEmpty else { return }
        queued.subtract(batch)
        inFlight.formUnion(batch)
        defer { inFlight.subtract(batch) }
        do {
            // A time limit (owner 2026-11-07: every card stuck on "Loading..."): a call that never
            // answered, e.g. across an account switch, kept its ids "in flight" for good, and an id in
            // flight is never asked again.
            let call = Functions.functions(region: "me-central1").httpsCallable("getQuotes")
            call.timeoutInterval = 15
            let r = try await call.call(["qids": batch])
            let got = ((r.data as? [String: Any])?["quotes"] as? [String: Any]) ?? [:]
            var changed = false
            for q in batch {
                fetchedAt[q] = Date()
                guard let d = got[q] as? [String: Any], let card = QuoteCard(d) else { continue }
                if cards[q] != card { cards[q] = card; changed = true }
            }
            if changed { trim(); LiveGroupCard.noteChanged(); scheduleSave() }
        } catch {
            // Asked again on the next draw after a short pause, not in a loop.
            let retryAt = Date().addingTimeInterval(-fresh + 15)
            for q in batch where fetchedAt[q] == nil || fetchedAt[q]! < retryAt { fetchedAt[q] = retryAt }
            // And asked again by itself: a card still on "Loading..." may never be drawn again to ask.
            let missing = batch.filter { cards[$0] == nil }
            if !missing.isEmpty {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard let self else { return }
                    for q in missing where self.cards[q] == nil { self.request(q) }
                }
            }
        }
        if !queued.isEmpty { await flush() }
    }

    /// Quote a channel post: the server checks I may see it and keeps a snapshot. Returns the id the
    /// message will carry, and seeds the card so my own bubble shows it at once.
    /// ⛔ THE CHAT OPENS BEFORE THE SERVER ANSWERS (owner 2026-11-06: "I pick the chat in Quote in and
    /// wait seconds before it opens"). The quote is made in the background under a local token; the
    /// composer shows the card at once from the post on screen, and asks `made(_:)` for the real id
    /// when it needs it (a send). One request per quote, however many times it is asked.
    struct Made { let qid: String; let card: QuoteCard; let picture: Data? }
    private var pending: [String: Task<Made, Error>] = [:]
    /// Finished quotes by token, without their picture bytes (2026-11-06 audit: every Task kept its
    /// JPEG for the whole session). The few most recent are enough for a late send.
    private var done: [String: (qid: String, card: QuoteCard)] = [:]

    func start(cid: String, mid: String, picture: @escaping () async -> Data?) -> String {
        let token = UUID().uuidString
        pending[token] = Task { @MainActor in
            let pic = await picture()
            let r = try await Self.create(cid: cid, mid: mid, picture: pic)
            return Made(qid: r.qid, card: r.card, picture: pic)
        }
        return token
    }

    func made(_ token: String) async throws -> Made {
        if let d = done[token] { return Made(qid: d.qid, card: d.card, picture: nil) }
        guard let t = pending[token] else { throw NSError(domain: "Quote", code: 2) }
        let m: Made
        do { m = try await t.value } catch {
            pending[token] = nil   // a failed attempt is not asked again (a retry starts a new one)
            throw error
        }
        if pending[token] != nil {
            pending[token] = nil
            if done.count > 20 { done.removeAll() }
            done[token] = (m.qid, m.card)
        }
        return m
    }

    static func create(cid: String, mid: String, picture: Data? = nil) async throws -> (qid: String, card: QuoteCard) {
        var args: [String: Any] = ["cid": cid, "mid": mid]
        // The post's picture as this phone has it open (channel media is sealed; see createQuote).
        if let picture { args["image"] = picture.base64EncodedString() }
        let r = try await Functions.functions(region: "me-central1").httpsCallable("createQuote").call(args)
        guard let d = r.data as? [String: Any], let qid = d["qid"] as? String, isQid(qid) else {
            throw NSError(domain: "Quote", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't quote this post."])
        }
        var card = QuoteCard(state: .ok)
        card.cid = cid; card.mid = mid
        card.title = d["title"] as? String ?? ""
        card.photoUrl = d["photoUrl"] as? String ?? ""
        card.username = d["username"] as? String ?? ""
        card.text = d["text"] as? String ?? ""
        card.kind = d["kind"] as? String ?? "text"
        card.image = d["image"] as? String ?? ""
        await MainActor.run { shared.seed(qid, card) }
        return (qid, card)
    }
}
